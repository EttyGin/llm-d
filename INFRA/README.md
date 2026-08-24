# INFRA — Precise Prefix Cache Routing @ llm-d v0.9.0

תשתית מלאה, נעולת-גרסאות, לפריסה בסיסית של מסלול ה-**precise prefix cache aware routing**
של llm-d, בשני מצבי הפעלה: **Standalone** ו-**Gateway**.

הכול כאן נגזר מתגית `v0.9.0` של הריפו הזה (לא מ-`main`, שכבר הצף חלק מהגרסאות
ל-`latest`). `env.sh` מחזיר את הנעילות המקוריות, כך שהפריסה נשארת יציבה גם אחרי
שאפסטרים זז.

---

## מה זה עושה בכלל

כל פוד vLLM משדר אירועי KV-cache ב-ZMQ. ה-Router (רכיב ה-EPP) נרשם לכל פוד
בנפרד, בונה אינדקס לפי block-hash, ולכל בקשה נכנסת:

1. **מטוקן** את הפרומפט מול שירות ה-render (קריאת HTTP ל-`/v1/*/render`),
2. **מסנן** (`prefix-cache-affinity-filter`) רק לפודים שבהם הפרפיקס כבר יושב בזיכרון,
3. **מנקד** (`token-load-scorer`) ובוחר מתוכם את הפוד עם עומס הטוקנים הנמוך ביותר.

זה ההבדל מ-prefix-cache routing מקורב: כאן היחס המדויק של הבלוקים הרזידנטיים
מגיע מאירועים אמיתיים של המנוע, לא מהערכה.

---

## מבנה התיקייה

> [`CLAUDE.md`](CLAUDE.md) — הסבר מלא על מה חדש ב-0.9.0, החלטות התכנון של ה-umbrella, וכל המלכודות שעולות זמן. תתחילי משם אם את (או סוכן) חוזרת לעץ הזה אחרי הפסקה.

```
INFRA/
├── CLAUDE.md                  ← מה חדש ב-0.9.0 + מלכודות
├── env.sh                     ← כל הגרסאות הנעולות. תמיד source לפני הכול
├── images.txt                 ← רשימת האימג'ים הליבתית (GPU + vLLM)
├── images-gateway.txt         ← אימג'ים נוספים למצב Gateway
├── images-alt-backends.txt    ← אימג'ים לבקאנדים חלופיים (SGLang/AMD/XPU/TPU)
├── charts/                    ← ה-Helm charts עצמם, משוכים מ-ghcr (v0.10.0)
│   ├── llm-d-router-standalone-v0.10.0.tgz
│   └── llm-d-router-gateway-v0.10.0.tgz
├── crds/                      ← Gateway API v1.5.1 + GAIE v1.5.0, מוכנים ל-apply לוקאלי
├── values/                    ← קבצי ה-values של ה-charts (שכבות)
├── manifests/
│   ├── kustomize/             ← עץ kustomize עצמאי (modelserver / render / gateway recipes)
│   └── rendered/              ← אותו דבר אחרי kustomize build — מוכן ל-apply או ל-GitOps
│       └── reference/         ← פלט helm template לעיון/דיף (לא להתקנה)
├── scripts/                   ← 00→05 לפי סדר, + mirror-images + uninstall
└── docs/
    ├── VERSIONS.md            ← מטריצת גרסאות מלאה
    ├── IMAGES.md              ← כל אימג' — למה הוא נחוץ ומתי
    └── GATEWAY-MODE.md        ← מה בדיוק משתנה במצב Gateway
```

---

## דרישות מקדימות

* קלאסטר Kubernetes 1.28+ (שלוש הגרסאות האחרונות)
* `kubectl` 1.28+, `helm` 3.12+, `kustomize` 5.0+, `yq` v4+, `jq`
* הרשאות cluster-admin — להתקנת ה-CRDs (ובמצב Gateway, גם ל-control plane של הספק)
* טוקן HuggingFace ב-`HF_TOKEN`
* חומרה לברירת המחדל: **16 GPU** (8 רפליקות × TP=2, Qwen3-32B, H100 80GB).
  לצי קטן יותר — הקטיני `replicas` ב-`manifests/kustomize/precise-prefix-cache-routing/modelserver/gpu/vllm/base/patch-vllm.yaml`.

---

## התקנה — Standalone (ברירת מחדל)

```bash
source INFRA/env.sh

./INFRA/scripts/00-install-crds.sh          # Gateway API 1.5.1 + GAIE 1.5.0 (cluster-admin)
export HF_TOKEN=hf_xxx
./INFRA/scripts/02-namespace-and-secret.sh  # namespace + secret llm-d-hf-token

./INFRA/scripts/03-install-router.sh        # EPP + InferencePool + Envoy sidecar
./INFRA/scripts/04-install-modelserver.sh   # 8 פודי vLLM + שירות ה-render
./INFRA/scripts/05-verify.sh                # curl דרך הראוטר
```

נקודת הכניסה: `Service ${GUIDE_NAME}-epp` פורט `80` → סייד-קאר Envoy `:8081`.

## התקנה — Gateway

```bash
source INFRA/env.sh
export ROUTER_MODE=gateway
export GATEWAY_PROVIDER=agentgateway        # agentgateway | istio | gke | envoy-ai-gateway

./INFRA/scripts/00-install-crds.sh
export HF_TOKEN=hf_xxx
./INFRA/scripts/02-namespace-and-secret.sh
./INFRA/scripts/01-install-gateway.sh       # ← קודם ה-Gateway, אחר כך הראוטר
./INFRA/scripts/03-install-router.sh        # EPP + InferencePool + HTTPRoute (בלי Envoy)
./INFRA/scripts/04-install-modelserver.sh
ROUTER_MODE=gateway ./INFRA/scripts/05-verify.sh
```

הסדר קריטי: ה-`HTTPRoute` שה-chart יוצר מפנה בשם ל-`llm-d-inference-gateway`,
ולא יתקבל עד שה-Gateway קיים. פירוט מלא של ההבדלים ב-[docs/GATEWAY-MODE.md](docs/GATEWAY-MODE.md).

---

## הגרסאות הנעולות

| רכיב | גרסה |
| --- | --- |
| llm-d | `v0.9.0` |
| Gateway API CRDs | `v1.5.1` |
| GAIE CRDs | `v1.5.0` |
| llm-d Router charts + EPP | `v0.10.0` |
| vLLM (model server + render) | `v0.26.0` |
| Envoy sidecar (Standalone) | `distroless-v1.33.2` |
| agentgateway (Gateway) | `v1.1.0` |
| Istio (Gateway) | `1.29.2` |

גרסת הראוטר (`v0.10.0`) גבוהה מגרסת llm-d (`v0.9.0`) — הם מתוגרסים בנפרד. זו לא טעות.

מטריצה מלאה: [docs/VERSIONS.md](docs/VERSIONS.md).

---

## האימג'ים

**ליבה (חובה, GPU + vLLM):**

```
docker.io/vllm/vllm-openai:v0.26.0                        # model server + render
ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0        # ה-EPP — הרכיב שמנתב
docker.io/envoyproxy/envoy:distroless-v1.33.2             # Standalone בלבד
cfmanteiga/alpine-bash-curl-jq                            # אימות בלבד
```

**Gateway (לפי ספק):**

```
cr.agentgateway.dev/controller:v1.1.0 + cr.agentgateway.dev/agentgateway:v1.1.0
docker.io/istio/pilot:1.29.2 + docker.io/istio/proxyv2:1.29.2
GKE — מנוהל, אין מה למשוך
```

**רק אם מחליפים טופולוגיית render או בקאנד:**
`docker.io/vllm/vllm-openai-cpu:v0.26.0` (בריכת render ייעודית — **חובה ל-SGLang**),
`lmsysorg/sglang:v0.5.16.0`, `vllm-openai-rocm`, `vllm-openai-xpu`, `vllm-tpu` — כולם `v0.26.0`.

הסבר מלא למה כל אימג' נחוץ: [docs/IMAGES.md](docs/IMAGES.md).

**סביבה מנותקת:**

```bash
TARGET_REGISTRY=registry.internal/llm-d LISTS="images.txt images-gateway.txt" \
  ./INFRA/scripts/mirror-images.sh
```

---

## ה-Charts

| Chart | גרסה | מתקין |
| --- | --- | --- |
| `oci://ghcr.io/llm-d/charts/llm-d-router-standalone` | `v0.10.0` | EPP + Envoy sidecar + InferencePool + RBAC |
| `oci://ghcr.io/llm-d/charts/llm-d-router-gateway` | `v0.10.0` | EPP + InferencePool + HTTPRoute + תוספות לפי ספק |

שניהם משוכים כבר ל-`charts/` — להתקנה בלי רשת:
`CHART_SOURCE=local ./INFRA/scripts/03-install-router.sh`.

שכבות ה-values (הסדר משנה, האחרון מנצח):

```
values/base.values.yaml                             ← משאבים, ארגומנטי Envoy, failureMode
  + values/httproute-flags.yaml                     ← Gateway בלבד
  + values/monitoring.values.yaml                   ← אופציונלי (דורש Prometheus Operator)
  + values/precise-prefix-cache-routing.values.yaml ← ⭐ שרשרת הפלאגינים — הלב של המדריך
```

> `helm upgrade` **לא** יורש values מהתקנה קודמת. חזרי על כל ה-`-f` וה-`--set` המקוריים,
> אחרת הם חוזרים לברירות המחדל של ה-chart.

---

## פרמטרים שחייבים להישאר מסונכרנים

| פרמטר | ערך | איפה |
| --- | --- | --- |
| גודל בלוק | `64` | `--block-size=64` ב-vLLM **וגם** `tokenProcessorConfig.blockSizeTokens: 64` ב-values. חייבים להיות זהים. ב-SGLang זה `--page-size=64`. |
| שם המודל | `Qwen/Qwen3-32B` | ה-`args` של ה-modelserver **וגם** `token-producer.modelName`. אי-התאמה נדחית מיידית. |
| שם ה-release | `${GUIDE_NAME}` | חובה — סלקטור ה-InferencePool נבנה ממנו ומתאים ל-label `llm-d.ai/guide`. |
| רפליקות EPP | `1` | ה-`token-load-scorer` סופר טוקנים לוקאלית לכל תהליך; שתי רפליקות active-active יראו כל אחת חצי מהעומס ויטעו בסינון. |
| `peakPrefillThroughput` | `15926` | מכויל ל-Qwen3-32B / H100 / TP=2. לחומרה אחרת — לכייל מחדש. |
| פורטים 5556 / 5559 | KV events / replay | חשופים בפוד ה-vLLM, ו-`podDiscoveryConfig` בראוטר מצפה להם. |

---

## סדר הפעולות — ולמה

1. **CRDs** — לפני הכול; ה-chart יוצר `InferencePool`.
2. **Gateway** (במצב Gateway בלבד) — לפני הראוטר, כי ה-`HTTPRoute` מפנה אליו בשם.
3. **Router** — יוצר את ה-InferencePool ואת ה-EPP.
4. **Model servers** — נטענים לאט (weights). המתיני ל-`Ready` לפחות של אחד.
5. **render Service** — **אחרי** המודל-סרברים. באוברליי ברירת המחדל אין לו פודים משלו,
   הוא בוחר את פודי ה-decode. עד שאין פוד `Ready` אין endpoints, וקריאות
   ה-`token-producer` ייכשלו. `04-install-modelserver.sh` כבר עושה את זה בסדר הנכון.

---

## הסרה

```bash
./INFRA/scripts/99-uninstall.sh          # הכול חוץ מה-CRDs
./INFRA/scripts/99-uninstall.sh --crds   # כולל ה-CRDs (זהירות — cluster-scoped, משותפים)
```

---

## מדריכים נוספים בתיקייה

| תיקייה | מה יש בה |
| --- | --- |
| [`chart/`](chart/README.md) | **Umbrella chart** — release אחד שפורס Router (EPP) + model servers, עם זהות אחת ב-`global.llmd` שמתפשטת לשני ה-subcharts וגם ל-chart שעוטף את ה-umbrella. עוטף את `llm-d-router-gateway` v0.10.0 (vendored + patched) ואת ה-modelserver, עם 14 דוגמאות values. |
| [`guides/deepseek-v4-flash-pd/`](guides/deepseek-v4-flash-pd/README.md) | DeepSeek-V4-Flash-0731 על H100 — P/D disaggregation (8 GPU prefill / 4 GPU decode), wide-EP עם DEP ו-TP=1 בלי LWS, all2all של DeepEP, CPU offloading ו-P2P KV sharing. ארוז כ-Helm chart מלא עם שכבות values שדורסות, ו-README מפורט באנגלית. |

---

## מה לא נכלל כאן בכוונה

* **בנצ'מרקים** — `llmdbenchmark` הוא כלי נפרד; ראי את סעיף ה-Benchmarking במדריך המקורי.
* **מוניטורינג** — ה-values מוכן (`values/monitoring.values.yaml`,
  `ENABLE_MONITORING=true`), אבל מחסנית Prometheus/Grafana עצמה היא תשתית נפרדת
  (`docs/operations/observability/setup.md` בריפו).
* **P/D disaggregation** — מדריך אחר; ה-routing sidecar לא נחוץ כאן.
* **wide-EP LWS** — לפריסות multi-port DP יש וריאנט נפרד של אותו ניתוב.
