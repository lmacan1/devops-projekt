# Secure Event Ticketing Platform (Sample DevSecOps Project)

Ovaj repozitorij je referentni uzorak aplikacije za kolegij **Uvod u DevOps - DevSecOps**.
Prikazuje cijeli tok: lokalni razvoj kroz Compose i produkcijski deployment kroz Kubernetes manifeste.

## Arhitektura

- `frontend` - web UI za pregled evenata i kupnju karata
- `api` - REST API za evente, narudzbe i health provjere
- `worker` - pozadinska obrada queue poruka
- `postgres` - trajna pohrana narudzbi
- `redis` - queue/cache sloj

### Brza validacija funkcionalnosti

1. Health API:
   ```bash
   curl http://localhost:8080/healthz
   curl http://localhost:8080/readyz
   ```
2. Dohvati evente:
   ```bash
   curl http://localhost:8080/events
   ```
3. Posalji narudzbu:
   ```bash
   curl -X POST http://localhost:8080/tickets/purchase \
     -H "Content-Type: application/json" \
     -d '{"eventId":"evt-1001","customerEmail":"student@example.com","quantity":2}'
   ```
4. Provjeri obradene narudzbe:
   ```bash
   curl http://localhost:8080/tickets/orders
   ```
5. UI:
   - Otvori `http://localhost:3000`

## Sigurnosni elementi

- Multi-stage Docker build i non-root runtime korisnik
- Secret + ConfigMap odvojena konfiguracija
- Liveness/Readiness sonde
- Resource requests/limits
- ServiceAccount + RBAC
- NetworkPolicy segmentacija
- Trivy skeniranje slika u CI pipelineu (`exit-code: 1` quality gate)
- SemVer tagiranje slika (`v1.2.3`, `1.2`, `1`, `latest`) + commit-sha
- Dependabot weekly PR-ovi (npm, docker base, github-actions)
- Retention policy — čuva se zadnjih 10 untagged verzija po slici

## Dokumentacija

- `docs/architecture.md` — arhitekturni dijagram, tok podataka, kontejneri vs. VM
- `docs/delivery-metrics.md` — baseline vs. pipeline, DORA metrike
- `docs/security/` — Trivy izvještaji po servisu
- `RUNBOOK.md` — operativni priručnik za incidente (symptom → dijagnoza → uzrok → ispravak → validacija)

## Release postupak

```bash
# Tagiraj i pushaj SemVer tag — pipeline objavljuje v1.2.3, 1.2, 1, latest
git tag v1.2.3
git push origin v1.2.3
```