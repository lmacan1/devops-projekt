# Arhitektura sustava

## Kontekstni dijagram

```
                                   ┌───────────────────────────┐
                                   │        Korisnik           │
                                   │   (preglednik, curl)      │
                                   └─────────────┬─────────────┘
                                                 │ HTTPS / HTTP
                                                 ▼
                                   ┌───────────────────────────┐
                                   │   Ingress / OpenShift     │
                                   │   Route (NetworkPolicy)   │
                                   └─────────┬─────────────────┘
                                             │
                        ┌────────────────────┴────────────────────┐
                        │                                         │
                        ▼                                         ▼
          ┌───────────────────────┐                 ┌─────────────────────────┐
          │  frontend (Node.js)   │  GET /events    │   api (Express/Node)    │
          │  Containerfile:       │◄────────────────┤   Containerfile:        │
          │    multi-stage,       │                 │     multi-stage,        │
          │    non-root 10001     │  POST /tickets  │     non-root 10001      │
          │  Port: 3000           │────────────────►│   Port: 8080            │
          │  Probe: /healthz      │                 │   Probe: /healthz,/readyz│
          └───────────────────────┘                 └──────┬─────────┬────────┘
                                                           │         │
                                                   RPUSH   │         │  SQL
                                                   orders  │         │  read/write
                                                           ▼         ▼
                                               ┌──────────────┐  ┌──────────────────┐
                                               │   redis      │  │   postgres       │
                                               │   (queue +   │  │   (persistent    │
                                               │    cache)    │  │    storage)      │
                                               │   Port: 6379 │  │   Port: 5432     │
                                               └──────▲───────┘  └────────▲─────────┘
                                                      │                   │
                                                BLPOP │                   │ INSERT
                                                orders│                   │ orders
                                                      │                   │
                                                      └────┬──────────────┘
                                                           │
                                                           ▼
                                               ┌────────────────────────┐
                                               │  worker (Node.js)      │
                                               │  Containerfile:        │
                                               │    multi-stage,        │
                                               │    non-root 10001      │
                                               │  Headless (no HTTP)    │
                                               └────────────────────────┘
```

## Tok podataka — kupnja karte

1. **Korisnik** → `POST /tickets/purchase` na `api` servisu.
2. **api** validira payload, generira `orderId`, `RPUSH` u `redis` red `orders:new`, vraća `HTTP 202 Accepted`.
3. **worker** na `BLPOP orders:new` preuzima zadatak, obrađuje (naplata, rezervacija), `INSERT` u `postgres` tablicu `orders`.
4. **Frontend** povremeno pollira `GET /tickets/orders` za prikaz stanja korisniku.

## Kubernetes resursi po servisu

| Resurs | api | worker | frontend | postgres | redis |
|--------|-----|--------|----------|----------|-------|
| Deployment | ✓ (3 replike) | ✓ (2 replike) | ✓ (2 replike) | ✓ (1, PVC) | ✓ (1) |
| Service | ClusterIP | — (headless) | ClusterIP | ClusterIP | ClusterIP |
| Ingress/Route | ✓ | — | ✓ | — | — |
| ConfigMap | ✓ | ✓ | ✓ | ✓ | — |
| Secret | DB_PASSWORD | DB_PASSWORD | — | POSTGRES_PASSWORD | — |
| Liveness probe | `/healthz` | — (process-level) | `/healthz` | `pg_isready` | `redis-cli ping` |
| Readiness probe | `/readyz` | — | `/healthz` | `pg_isready` | `redis-cli ping` |
| NetworkPolicy (ingress) | from: Ingress | from: api | from: Ingress | from: api,worker | from: api,worker |

## Izbor tehnologije — kontejneri vs. virtualni strojevi

| Svojstvo | Kontejneri (Podman/Docker) | Virtualni strojevi (KVM/VMware) |
|----------|---------------------------|--------------------------------|
| **Izolacija** | Namespace + cgroups — dijele jezgru s domaćinom | Hardverska — potpuno odvojena jezgra po instanci |
| **Overhead** | ~10–50 MB po procesu, start < 1 s | ~500 MB–2 GB po instanci, start 30–120 s |
| **Portabilnost** | OCI image radi na svakom OCI-kompatibilnom runtimeu | Ovisnost o hipervizoru, alatu za snapshot, formatu diska |
| **Sigurnosni granice** | Slabiji izolacijski sloj; rizik kernel escape-a ako aplikacija ima root | Jača izolacija; kompromitacija gosta rijetko zahvaća domaćina |
| **Gustoća** | 50–500 kontejnera po hostu (ovisno o resursima) | 5–50 VM-ova po hostu |
| **CI/CD integracija** | Nativno — image je deploy artefakt, layer caching, reproducibilni build | Dodatni sloj (Packer, Ansible), sporiji feedback loop |
| **Use case** | Stateless servisi, mikroservisi, kratkotrajni jobovi | Legacy monoliti, aplikacije koje zahtijevaju poseban kernel / drajvere, multi-tenant strogo izolirani workloadovi |

**Za ovu aplikaciju** (stateless API, stateless worker, stateless frontend + upravljani state u postgres/redis) kontejneri su ispravan izbor:
- brži CI/CD ciklus (< 1 min build + push)
- deterministični build kroz multi-stage Containerfile
- jednaka slika u razvoju (Podman Compose) i produkciji (Kubernetes) — eliminira "works on my machine"
- OWASP preporuke za kontejnere (non-root user, minimalni base image, read-only FS gdje je moguće) lako se primjenjuju na razini Containerfilea

**Ograničenja** (koja se rješavaju konfiguracijom):
- slabiji izolacijski sloj → kompenzira se `runAsNonRoot`, `readOnlyRootFilesystem`, `seccompProfile: RuntimeDefault`, NetworkPolicy
- persistentni state → PVC za postgres, ne čuva se u kontejnerskom FS-u

## Sigurnosni sloj po komponenti

```
┌─ Image layer ────────────────────────────────────────────┐
│ • Multi-stage build (builder → runtime)                   │
│ • Non-root user (UID 10001)                               │
│ • Minimalni base: node:20-alpine                          │
│ • Trivy skeniranje u CI (CRITICAL/HIGH, --ignore-unfixed) │
│ • Dependabot: npm + docker base + gh-actions weekly       │
└──────────────────────────────────────────────────────────┘
┌─ Runtime (Kubernetes) ────────────────────────────────────┐
│ • ServiceAccount + RBAC (least-privilege)                 │
│ • NetworkPolicy (default deny, explicit allow po servisu) │
│ • Secret (base64, mountan iz Kubernetes, ne u image)      │
│ • Resource requests/limits na svakom kontejneru           │
│ • Liveness/readiness sonde                                │
└──────────────────────────────────────────────────────────┘
┌─ Pipeline ────────────────────────────────────────────────┐
│ • GitHub Actions, OIDC token za GHCR push                 │
│ • Quality gate — exit-code: 1 na rješivim CVE-ima         │
│ • SemVer + commit-sha + latest tagovi                     │
│ • Retention — brisanje untagged image verzija             │
└──────────────────────────────────────────────────────────┘
```
