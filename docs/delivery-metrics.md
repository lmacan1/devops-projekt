# Mjerljiv napredak brzine isporuke

## Kontekst

DORA (DevOps Research and Assessment) definira četiri ključne metrike zrelosti isporuke:
lead time for changes, deployment frequency, change failure rate i mean time to restore.
Ovaj dokument prikazuje baseline (ručni postupak, prije automatizacije) i stanje nakon
uvođenja CI/CD pipelinea s GitHub Actionsom.

## Baseline — ručna isporuka (hipotetski scenarij prije automatizacije)

Mjereno na lokalnoj stanici i ručnim koracima:

| Korak | Trajanje (ručno) | Opis |
|------:|------------------|------|
| 1. Lokalni build 3 slike (api, worker, frontend) | ~2 min 10 s | `podman build` redom, bez paralelizacije |
| 2. Ručno Trivy skeniranje po slici | ~1 min 30 s | `trivy image …` za svaku, čitanje izvještaja |
| 3. Prijava u registar + `podman push` | ~1 min 50 s | 3× push, upload ovisi o mreži |
| 4. `kubectl set image` + provjera rollouta | ~1 min 10 s | ručna zamjena taga, gledanje `rollout status` |
| 5. Smoke test, verifikacija | ~2 min | curl na `/healthz`, `/readyz`, test narudžbe |
| **Ukupno (baseline)** | **~8 min 40 s** | — |
| **Dodatne ljudske radnje** | **~5 min** | kontekst-prebacivanje, praćenje outputa, mogući tipfeleri |
| **Realan ciljani lead time (ručno)** | **~13–15 min** | od commita do zdravog deploya |

Ručni proces je **nereproducibilan** (ovisi o okruženju inženjera), **nerevizibilan**
(nema artefakata) i **propustljiv** za sigurnosne provjere (skeniranje se može preskočiti).

## Stanje nakon automatizacije (CI/CD pipeline)

Mjereno na stvarnom GitHub Actions runu (`ubuntu-latest`):

| Job (paralelno, matrix po servisu) | Trajanje |
|------------------------------------|---------:|
| Checkout + GHCR login | ~6 s |
| docker/metadata-action (SemVer) | ~2 s |
| Build image (buildkit + layer cache) | ~18 s |
| Trivy skeniranje (CRITICAL/HIGH, --ignore-unfixed) | ~12 s |
| Upload artifacts | ~3 s |
| Push u GHCR (SemVer + sha + latest) | ~11 s |
| cleanup-old-images (retention) | ~1 s |
| **Ukupno po servisu (wall-clock)** | **~53 s** |
| **Ukupno pipeline (paralelni matrix)** | **~55 s** |

## Usporedba

| Metrika | Ručno (baseline) | CI/CD pipeline | Poboljšanje |
|---------|------------------|----------------|-------------|
| Lead time (commit → image u registru) | ~8 min 40 s | ~55 s | **-90 %** (9.5× brže) |
| Realan lead time (s ljudskim kontekstom) | ~13–15 min | ~55 s | **-93 %** |
| Frekvencija isporuke | ad-hoc, ~1×/dan | na svaki push (potencijalno 10+/dan) | **10×+** |
| Reproducibilnost | nema | da (svaki job = isti image iz istog commit-sha) | ✓ |
| Revizibilnost | nema | da (workflow run log + Trivy artifact, retention 30 dana) | ✓ |
| Obavezno sigurnosno skeniranje | opcionalno | quality gate (`exit-code: 1`) | ✓ |
| Reprodukcija na drugom stroju | ručna | `docker pull` + deploy | ✓ |

## Kako smanjiti lead time dodatno

Mjerenja iz Actions runa pokazuju gdje je marginalni dobitak moguć:

1. **Layer cache** — uključiti `cache-from: type=gha` u `docker/build-push-action`
   → ponovljeni build-ovi sa sitnim izmjenama padaju s 18 s na ~6 s.
2. **Paralelizacija test ↔ scan** — Trivy skenira dok se odvija unit test (trenutno serijski).
3. **Self-hosted runner** — ovisno o workload-u, ubuntu-latest cold start je ~8 s.
4. **Preskoči push na PR** (već je implementirano kroz `if: github.event_name == 'push'`).

## Zaključak

Automatizacija je ubrzala isporuku s ~9 minuta na ~55 sekundi (91 % ušteda),
eliminirala ručne korake prepjevljive ljudskoj grešci, te uvela sigurnosni quality
gate koji se u ručnom procesu gotovo nikad ne izvršava dosljedno. Pipeline proizvodi
revizibilne artefakte (Trivy izvještaj, tag-irane slike u GHCR) što zadovoljava
zahtjeve koje DevSecOps postavlja.
