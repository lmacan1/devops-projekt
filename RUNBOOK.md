# Runbook — Secure Event Ticketing Platform

Operativni priručnik za dijagnostiku i ispravak incidenata u produkcijskom Kubernetes okruženju.
Svaki incident strukturiran je prema predlošku: **Simptom → Dijagnoza → Uzrok → Ispravak → Validacija → Prevencija**.

---

## Incident 1: Pad baze podataka (PostgreSQL nedostupan)

### Simptom
- API vraća `HTTP 503 Service Unavailable` na `/readyz`.
- Worker logovi ponavljaju `Error: connect ECONNREFUSED postgres:5432`.
- Narudžbe nisu trajno pohranjene, a red čekanja u Redisu raste.
- `kubectl get pods -n ticketing` prikazuje postgres pod u stanju `CrashLoopBackOff` ili `0/1 Running`.

### Dijagnoza
```bash
# 1. Stanje podova i posljednji eventi
kubectl get pods -n ticketing -o wide
kubectl describe pod -l app=postgres -n ticketing
kubectl get events -n ticketing --sort-by=.lastTimestamp | tail -20

# 2. Logovi baze
kubectl logs deployment/postgres -n ticketing --tail=100
kubectl logs deployment/postgres -n ticketing --previous --tail=50

# 3. Provjera perzistentne pohrane
kubectl get pvc -n ticketing
kubectl describe pvc postgres-data -n ticketing

# 4. Provjera resursa (OOMKilled?)
kubectl top pod -n ticketing
```

### Uzrok
Tipični uzroci (po učestalosti):
1. **OOMKilled** — pod je prekoračio `resources.limits.memory` tijekom pikova opterećenja.
   Indikator: `Last State: Terminated, Reason: OOMKilled, Exit Code: 137` u `kubectl describe`.
2. **PVC nije bindan / storage class problem** — pod ne može montirati `postgres-data`.
   Indikator: `events` prikazuju `FailedMount` ili `waiting for a volume to be created`.
3. **Corrupt data directory** — nakon ungraceful shutdowna PostgreSQL odbija start.
   Indikator: `FATAL: database files are incompatible` ili `could not open file "pg_wal/..."` u logovima.

### Ispravak
```bash
# A. Ako je OOMKilled — podigni memory limit i restart
kubectl patch deployment postgres -n ticketing --patch '
spec:
  template:
    spec:
      containers:
        - name: postgres
          resources:
            limits:
              memory: "512Mi"
            requests:
              memory: "256Mi"
'
kubectl rollout restart deployment/postgres -n ticketing
kubectl rollout status deployment/postgres -n ticketing --timeout=120s

# B. Ako je PVC problem — provjeri storage klasu i re-kreiraj
kubectl get sc
kubectl delete pod -l app=postgres -n ticketing  # force re-mount

# C. Ako je corrupt data — hitni rollback na prethodni snapshot (SAMO ako postoji backup)
# kubectl exec -it deployment/postgres -n ticketing -- pg_dumpall > /dev/null  # test
```

### Validacija
```bash
# 1. Pod je Ready
kubectl get pod -l app=postgres -n ticketing
# OČEKIVANO: STATUS=Running, READY=1/1

# 2. Baza prihvaća konekcije iznutra
kubectl exec -it deployment/postgres -n ticketing -- \
  pg_isready -U ticketing -d ticketing
# OČEKIVANO: "/var/run/postgresql:5432 - accepting connections"

# 3. API ready endpoint prolazi
kubectl exec -it deployment/api -n ticketing -- curl -s localhost:8080/readyz
# OČEKIVANO: HTTP 200 i JSON {"status":"ok","db":"ok","redis":"ok"}

# 4. Worker je obradio zaostalu seriju poruka
kubectl logs deployment/worker -n ticketing --tail=50 | grep "order processed"

# 5. End-to-end test kupnje
curl -s -X POST http://<ingress-host>/tickets/purchase \
  -H "Content-Type: application/json" \
  -d '{"eventId":"evt-1001","customerEmail":"smoke@test.hr","quantity":1}' | jq .
# OČEKIVANO: HTTP 202 + orderId
```

### Prevencija
- Postaviti `resources.limits` prema 95. percentilu promatrane potrošnje + 30% rezerve.
- Uključiti dnevni `pg_dump` CronJob u isti namespace s retencijom 7 dana.
- Konfigurirati PodDisruptionBudget za postgres (`minAvailable: 1`) kako voluntary evictioni ne bi ostavili bazu offline.

---

## Incident 2: Neispravan image tag (ImagePullBackOff / ErrImagePull)

### Simptom
- `kubectl get pods -n ticketing` prikazuje jedan ili više podova u `ImagePullBackOff` ili `ErrImagePull`.
- Deployment je na `0/3` ili `READY=1/3` — nova replika ne starta.
- Korisnici vide pad dostupnosti ako `maxUnavailable > 0`.

### Dijagnoza
```bash
POD=$(kubectl get pod -n ticketing -l app=api -o jsonpath='{.items[0].metadata.name}')
kubectl describe pod $POD -n ticketing | grep -A 5 Events
kubectl get events -n ticketing --field-selector reason=Failed
```

### Uzrok
Tipični uzroci:
1. **Tipfeler u tagu** — deployment referencira `:v1.2.4` koji ne postoji u registru.
2. **Registry autentikacija** — `imagePullSecret` istekao ili nije montiran u ServiceAccount.
3. **Private image, public cluster node** — node nema pristup ghcr.io, ili token nema `read:packages` scope.

### Ispravak
```bash
# A. Brza mjera — vrati se na prethodni poznati radni revision
kubectl rollout undo deployment/api -n ticketing
kubectl rollout status deployment/api -n ticketing --timeout=60s

# B. Ciljan rollback na konkretnu reviziju
kubectl rollout history deployment/api -n ticketing
kubectl rollout undo deployment/api -n ticketing --to-revision=3

# C. Ako je uzrok pull secret — re-kreiraj
kubectl delete secret ghcr-pull -n ticketing --ignore-not-found
kubectl create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<user> \
  --docker-password=<PAT> \
  -n ticketing
kubectl patch serviceaccount ticketing-sa -n ticketing \
  -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
kubectl rollout restart deployment/api -n ticketing
```

### Validacija
```bash
# 1. Sve replike Ready
kubectl rollout status deployment/api -n ticketing
kubectl get deploy api -n ticketing
# OČEKIVANO: READY=3/3 UP-TO-DATE=3 AVAILABLE=3

# 2. Nema više pull eventova
kubectl get events -n ticketing --field-selector reason=Failed | wc -l
# OČEKIVANO: 0

# 3. Servis odgovara
kubectl port-forward svc/api 8080:8080 -n ticketing &
curl -s localhost:8080/healthz
# OČEKIVANO: HTTP 200

# 4. Revision history
kubectl rollout history deployment/api -n ticketing | tail -5
```

### Prevencija
- U CI pipelineu tagirati slike `commit-sha` + SemVer (`v1.2.3`) — nikada `latest` u produkciji.
- Uključiti `imagePullPolicy: IfNotPresent` uz nepromjenjive (immutable) tagove.
- Dodati `kubectl diff` korak prije `apply` u deployment pipelineu.

---

## Incident 3: Neispravan Secret (krivi kredencijali za bazu)

### Simptom
- API i worker logovi pokazuju `FATAL: password authentication failed for user "ticketing"`.
- `/readyz` vraća 503 iako postgres pod radi normalno.
- `pg_isready` iz postgres poda radi, ali aplikacije ne mogu autenticirati.

### Dijagnoza
```bash
# 1. Potvrdi da je postgres live (isključi Incident 1)
kubectl exec deployment/postgres -n ticketing -- pg_isready

# 2. Dekodiraj secret i usporedi s onim što koristi postgres
kubectl get secret ticketing-secrets -n ticketing -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d

# 3. Provjeri koja verzija secreta je montirana u running pod
kubectl exec deployment/api -n ticketing -- printenv | grep -i POSTGRES

# 4. Logovi autentikacije baze
kubectl logs deployment/postgres -n ticketing | grep -i "authentication failed"
```

### Uzrok
- Secret je rotiran (`kubectl apply -f secret.yaml`) ali deploymenti nisu restartani → podovi i dalje drže staru vrijednost u envu.
  PostgreSQL je u međuvremenu pokupio novu lozinku (ako je inicijaliziran s njom) → mismatch.
- Base64 dvostruko kodiran: netko je `echo -n "pass" | base64 | base64` → secret sadrži `cGFzc3dvcmQ=` umjesto `pass`.
- Postgres pod kreiran je s `POSTGRES_PASSWORD` iz *starog* secreta; `initdb` se izvršio jednom i lozinka u PVC-u se ne mijenja pri običnom restartu.

### Ispravak
```bash
# 1. Generiraj novu lozinku (ili dohvati iz vaulta)
NEW_PASS=$(openssl rand -base64 32)
echo "Nova lozinka: $NEW_PASS"  # snimi sigurno

# 2. Promijeni lozinku U bazi (postgres PVC je perzistentan — init se ne ponavlja)
kubectl exec -it deployment/postgres -n ticketing -- \
  psql -U ticketing -d ticketing -c "ALTER USER ticketing WITH PASSWORD '$NEW_PASS';"

# 3. Ažuriraj Kubernetes Secret (base64 jednom!)
kubectl patch secret ticketing-secrets -n ticketing \
  --type='json' \
  -p='[{"op":"replace","path":"/data/POSTGRES_PASSWORD","value":"'"$(echo -n "$NEW_PASS" | base64 -w0)"'"}]'

# 4. Rollout-restart svih servisa koji koriste secret (env vars se čitaju samo pri startu)
kubectl rollout restart deployment/api deployment/worker -n ticketing
kubectl rollout status deployment/api -n ticketing --timeout=60s
kubectl rollout status deployment/worker -n ticketing --timeout=60s
```

### Validacija
```bash
# 1. Provjeri da su svi podovi pokrenuti nakon restarta
kubectl get pods -n ticketing -l 'app in (api,worker)'
# OČEKIVANO: svi Running, 1/1 Ready, RESTARTS nova kolona na 0

# 2. Readiness prolazi (testira konekciju na bazu)
kubectl exec deployment/api -n ticketing -- curl -s localhost:8080/readyz | jq .
# OČEKIVANO: {"status":"ok","db":"ok","redis":"ok"}

# 3. Nema više autentikacijskih grešaka u logovima
kubectl logs deployment/api -n ticketing --tail=100 | grep -i "authentication failed" | wc -l
kubectl logs deployment/worker -n ticketing --tail=100 | grep -i "authentication failed" | wc -l
# OČEKIVANO: 0 na oba

# 4. End-to-end: kupovina mora proći i upis u bazu vidljiv
curl -X POST http://<ingress>/tickets/purchase -d '{"eventId":"evt-1001","customerEmail":"rot@test.hr","quantity":1}' -H 'Content-Type: application/json'
kubectl exec -it deployment/postgres -n ticketing -- \
  psql -U ticketing -d ticketing -c "SELECT COUNT(*) FROM orders WHERE customer_email='rot@test.hr';"
# OČEKIVANO: count = 1
```

### Prevencija
- Secrete rotirati atomično: `ALTER USER` + `kubectl patch secret` + `rollout restart` u istoj skripti.
- Razmotriti ExternalSecrets + Vault/Sealed Secrets — nema base64 ručnog kodiranja.
- Alarm u Prometheusu na broj `authentication failed` logova > 5/min.

---

## Incident 4: Quality gate u CI pipelineu blokira release zbog HIGH ranjivosti

### Simptom
- GitHub Actions workflow prekinut na koraku `Scan image with Trivy`.
- Exit code nije 0; artifact `trivy-<service>.txt` prikazuje CRITICAL ili HIGH pronalaze.
- Merge na `main` i objava na GHCR ne izvršavaju se.

### Dijagnoza
```bash
# 1. Preuzmi Trivy izvještaj iz Actions artifacts
gh run download <run-id> -n trivy-report-api

# 2. Identificiraj pakete
grep -E '^(CRITICAL|HIGH)' trivy-api.txt | sort -u

# 3. Utvrdi je li ranjivost u runtime ili build sloju
podman run --rm ghcr.io/<org>/devops-projekt-api:<sha> \
  sh -c "npm ls <ranjivi-paket> 2>&1 || true"
```

### Uzrok
1. **Base image zastario** — `node:20-alpine` ima CVE riješen u noviioj verziji.
2. **Tranzitivna dev-dependency** — ranjivost u `glob`/`tar`/`minimatch` povučena kroz `vite` ili `eslint`.
3. **Nova CVE objavljena između dva builda** — koda nije mijenjan, baza CVE jest.

### Ispravak
```bash
# A. Base image update (prvo probaj — često rješava OS-razinu)
# U Containerfile-u promijeni FROM node:20-alpine → node:20.11-alpine (ili node:22-alpine)

# B. Tranzitivni fix kroz overrides (package.json)
# "overrides": { "minimatch": "^9.0.5", "glob": "^10.4.5" }
npm install
npm audit --production   # provjeri runtime ovisnosti

# C. Prihvati ranjivost ako je SAMO u builder fazi i ne može se riješiti
# — u Trivy pipelineu već imamo ignore-unfixed: true
# — dodatno, za konkretne CVE-ove kreiraj .trivyignore
echo "CVE-2024-XXXXX" >> .trivyignore
```

### Validacija
```bash
# 1. Lokalno skeniraj prije pusha
trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 \
  ghcr.io/<org>/devops-projekt-api:$(git rev-parse --short HEAD)

# 2. Potvrdi da runtime image nema ranjivosti
trivy image --severity CRITICAL,HIGH --ignore-unfixed --scanners vuln \
  ghcr.io/<org>/devops-projekt-api:<sha> | grep "Total:" 

# 3. Pipeline prolazi end-to-end
gh workflow run ci.yml
gh run watch
# OČEKIVANO: svi jobovi zeleni, slike objavljene
```

### Prevencija
- **Dependabot** otvara PR-ove tjedno za npm, docker base images i GitHub Actions (`.github/dependabot.yml`).
- **Trivy quality gate** s `exit-code: 1` i `ignore-unfixed: true` — blokira samo rješive ranjivosti.
- Mjesečni pregled `.trivyignore` liste (svaki ignorirani CVE mora imati datum isteka i razlog).

---

## Opće dijagnostičke naredbe

```bash
# Stanje cijelog namespacea
kubectl get all -n ticketing

# Eventi sortirani po vremenu
kubectl get events -n ticketing --sort-by=.lastTimestamp

# Resursi (CPU/RAM) po podu
kubectl top pod -n ticketing

# Tail logova svih replika deploymenta
kubectl logs -f deployment/api -n ticketing --all-containers=true

# Debug pod u istom namespaceu (za network/DNS probleme)
kubectl run tmp-shell --rm -i --tty --image=nicolaka/netshoot -n ticketing -- /bin/bash

# Health probe iznutra
kubectl exec -it deployment/api -n ticketing -- curl -s localhost:8080/healthz
kubectl exec -it deployment/api -n ticketing -- curl -s localhost:8080/readyz

# Lokalni stack (razvoj)
podman-compose up -d
podman-compose logs -f api
podman-compose down -v
```

---

## Eskalacija

| Razina | Uvjet | Kontakt |
|--------|-------|---------|
| L1 | Simptom iz runbooka, postupak daje očekivani rezultat | dežurni inženjer |
| L2 | Ispravak ne popravlja simptom nakon 15 minuta | DevOps tim lead |
| L3 | Gubitak podataka, breach, nedostupnost > 30 min | Tech lead + security officer |

Svaki incident upisati u post-mortem predložak (datum, trajanje, uzrok, ispravak, prevencija).
