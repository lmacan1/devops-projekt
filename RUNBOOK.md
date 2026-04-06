# Runbook - Secure Event Ticketing Platform

## Incident 1: Pad baze podataka (PostgreSQL)

**Simptomi:**
- API vraća 503 na `/readyz`
- Worker logovi pokazuju `connection refused`

**Dijagnoza:**
```bash
kubectl get pods -n ticketing
kubectl logs deployment/postgres -n ticketing
```

**Rješenje:**
```bash
# Restart postgres poda
kubectl rollout restart deployment/postgres -n ticketing
kubectl rollout status deployment/postgres -n ticketing
# Provjeri je li baza dostupna
kubectl exec -it deployment/api -n ticketing -- curl localhost:8080/readyz
```

---

## Incident 2: Neispravan image tag (loš deployment)

**Simptomi:**
- Podovi u statusu `ImagePullBackOff` ili `ErrImagePull`
- `kubectl get pods -n ticketing` pokazuje 0/1

**Dijagnoza:**
```bash
kubectl describe pod <pod-name> -n ticketing
kubectl get events -n ticketing
```

**Rješenje:**
```bash
# Rollback na prethodnu verziju
kubectl rollout undo deployment/api -n ticketing
kubectl rollout status deployment/api -n ticketing
# Provjeri podove
kubectl get pods -n ticketing
```

---

## Incident 3: Neispravan Secret (pogrešna lozinka)

**Simptomi:**
- API i worker ne mogu se spojiti na bazu
- Logovi pokazuju `authentication failed`

**Dijagnoza:**
```bash
kubectl get secret ticketing-secrets -n ticketing -o yaml
kubectl logs deployment/api -n ticketing
```

**Rješenje:**
```bash
# Ažuriraj secret (nova lozinka mora biti base64 encodirana)
echo -n "nova_lozinka" | base64
kubectl patch secret ticketing-secrets -n ticketing \
  --patch='{"data":{"POSTGRES_PASSWORD":"<base64_vrijednost>"}}'
# Restart servisa koji koriste secret
kubectl rollout restart deployment/api -n ticketing
kubectl rollout restart deployment/worker -n ticketing
```

---

## Opće korisne naredbe
```bash
# Status svih podova
kubectl get pods -n ticketing

# Logovi servisa
kubectl logs deployment/api -n ticketing
kubectl logs deployment/worker -n ticketing

# Health check
curl http://localhost:8080/healthz
curl http://localhost:8080/readyz

# Lokalni stack
podman-compose up -d
podman-compose down
```
