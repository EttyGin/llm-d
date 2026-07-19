# מדריך: Autoscaling (0.7.x מול 0.8.x) + הפעלת OTel/Jaeger — llm-d על minikube

מדריך מעשי שמסביר **בדיוק מה לעשות** כדי:
1. להפעיל tracing (OTel → Jaeger).
2. להפעיל autoscaling מבוסס מטריקות-EPP עם KEDA — גם על **גרסת EPP 0.7.x** וגם על **קו 0.8.x**.

כל מה שכתוב כאן אומת חי על הקלאסטר הזה (namespace `default`, release `optimized-baseline`,
EPP image `llm-d-inference-scheduler:v0.8.0`, מודל `qwen-0.5b` על vLLM CPU, Prometheus רגיל,
KEDA מותקן).

> **הערת גרסאות חשובה:** ב-registry הרשמי (`ghcr.io/llm-d/llm-d-inference-scheduler`) ה-tags
> שפורסמו הם `v0.7.0`, `v0.7.1`, `v0.8.0-rc.1/2`, `v0.8.0`. **אין `v0.8.1`** נכון לכתיבת המדריך —
> ה-0.8.x האחרון הוא `v0.8.0` (מה שאתה מריץ). כל מה שכתוב כאן על "0.8.x" אומת על `v0.8.0`; כשייצא
> `v0.8.1` הוא אמור להתנהג זהה (אותו מודל auth, אותם שמות מטריקות) — אבל **תמיד תאמת חי** (ראה כלל הזהב).

---

## סעיף 0 — Runbook מקצה לקצה למחסנית שלך (v0.8.0) ⭐

זה המסלול הלינארי המלא: הרץ מלמעלה למטה, כל שלב עם שער-אימות. אם אתה על 0.7.x — ראה חלק ג'
(ההבדל היחיד: מדלגים על שלב 3, ה-RBAC). כל הקבצים כבר קיימים ב-`own/`.

### שלב 0.1 — ודא prerequisites (המחסנית קיימת ורצה)
```bash
# (א) minikube רץ, וה-llm-d optimized-baseline פרוס: EPP + vLLM decode + gateway
kubectl get deploy -n default | grep -E 'optimized-baseline-epp|modelservice-decode|inference-gateway-istio'
# (ב) KEDA מותקן וה-External Metrics API זמין
kubectl get apiservice v1beta1.external.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}{"\n"}'   # → True
kubectl get deploy -n keda 2>/dev/null || kubectl get deploy -A | grep keda
# (ג) Prometheus רץ
kubectl get deploy prometheus -n default
```
אם KEDA חסר: התקן לפי https://keda.sh/docs/latest/deploy/ (`helm install keda kedacore/keda -n keda --create-namespace`).
אם Prometheus חסר: פרוס את `own/prometheus.yaml` (ConfigMap+Deployment+Service).

### שלב 0.2 — Tracing (OTel + Jaeger)  → פירוט בחלק א'
```bash
kubectl apply -f guides/recipes/observability/tracing/jaeger-all-in-one.yaml
kubectl apply -f guides/recipes/observability/tracing/otel-collector.yaml
kubectl rollout status deploy/jaeger -n default && kubectl rollout status deploy/otel-collector -n default
# אימות: tracing מופעל ב-EPP (own/all-values.yaml: inferenceExtension.tracing.enabled=true)
```

### שלב 0.3 — Flow Control ב-EPP  → פירוט בחלק ד' שלב 2
```bash
kubectl logs deploy/optimized-baseline-epp -n default | grep -iE 'Flow Control layer|FlowRegistry initialized'
# אם ריק: ודא featureGates: ["flowControl"] ב-own/all-values.yaml, ואז helm upgrade.
```

### שלב 0.4 — פתח את `/metrics` (RBAC — רק 0.8.x)  → פירוט בחלק ד' שלב 3
```bash
kubectl apply -f own/metrics-rbac.yaml
kubectl port-forward -n default svc/optimized-baseline-epp 19090:9090 &
TOKEN=$(kubectl create token default -n default --duration=1h)
curl -s -o /dev/null -w "metrics HTTP %{http_code}\n" -H "Authorization: Bearer $TOKEN" localhost:19090/metrics   # → 200
```

### שלב 0.5 — Prometheus סורק את ה-EPP  → פירוט בחלק ב'
```bash
kubectl create configmap prometheus-config -n default \
  --from-file=prometheus.yml=own/prometheus.yml --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/prometheus -n default && kubectl rollout status deploy/prometheus -n default
kubectl port-forward -n default svc/prometheus 19091:9090 &
curl -s 'localhost:19091/api/v1/targets?state=active' | grep -o '"job":"epp-metrics"[^}]*"health":"[a-z]*"'   # → up
```

### שלב 0.6 — קרא שמות מטריקות חי (כלל הזהב)
```bash
curl -s -H "Authorization: Bearer $TOKEN" localhost:19090/metrics | grep -E '^inference_pool_average_(running_requests|queue_size)'
```

### שלב 0.7 — החל את ה-ScaledObject  → פירוט בחלק ה'
```bash
kubectl apply -f own/scaledobject.yaml
kubectl get scaledobject qwen-decode-epp -n default          # READY=True
kubectl get hpa keda-hpa-qwen-decode-epp -n default          # KEDA יצר; TARGETS מתמלא
```

### שלב 0.8 — עומס + צפייה  → פירוט בחלק ו'
```bash
kubectl port-forward -n default svc/llm-d-inference-gateway-istio 18080:80 &
for i in $(seq 1 12); do curl -s -m 120 localhost:18080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-0.5b","prompt":"Write a very long detailed epic story:","max_tokens":512}' >/dev/null & done
watch -n2 'kubectl get hpa keda-hpa-qwen-decode-epp -n default; kubectl get pods -n default | grep decode'
# צפוי: TARGETS 0/3 → 10/3, REPLICAS 1→2, פוד שני Pending (RAM) — תקין.
```

### שלב 0.9 — Cleanup (כשמסיימים)  → פירוט בחלק ח'
```bash
kubectl delete -f own/scaledobject.yaml
```

---

## כלל הזהב 🏅

**קרא את שמות המטריקות מהendpoint החי — אל תסמוך על שום מדריך, כולל זה.**

בשטח מסתובבות **שלוש** סכימות שמות שונות לאותן מטריקות:

| מקור | שם "queue depth" | שם "running requests" |
|---|---|---|
| מסמכי 0.7.0 (מה שעקבת אחריו) | `inference_extension_flow_control_queue_size` | `inference_objective_running_requests` |
| המדריך ב-repo (`guides/workload-autoscaling/README.hpa-epp.md`) | `llm_d_epp_flow_control_queue_size` | `llm_d_epp_request_running` |
| **הendpoint החי של v0.8.0 (מאומת)** | `inference_extension_flow_control_queue_size` | `inference_objective_running_requests` |

הממצא: השמות `llm_d_epp_*` שבמדריך ה-repo **לא קיימים בכלל** ב-v0.8.0. הגרסה החיה שלך תואמת
דווקא את שמות ה-0.7.0 (`inference_*`). לכן — לפני כל ScaledObject, הרץ:

```bash
# פתח port-forward למטריקות ה-EPP (ראה §3 לגבי הטוקן), ואז:
curl -s -H "Authorization: Bearer $TOKEN" localhost:19090/metrics | grep -E 'queue_size|running_requests'
```

---

## מפת ההבדלים 0.7.x ↔ 0.8.x (התקציר)

| נושא | 0.7.x | 0.8.x (מאומת על v0.8.0) | מה זה אומר לך |
|---|---|---|---|
| **auth על `/metrics`** | לרוב **פתוח** (200 בלי טוקן) | **מוגן** (401 בלי טוקן) | ב-0.8.x צריך RBAC + bearer token כדי לסרוק. זה ההבדל התפעולי הגדול. |
| **שמות מטריקות** | `inference_*` | `inference_*` (זהה) | ברוב המקרים אין שינוי — אבל תאמת חי. |
| **Flow Control** | feature gate | `featureGates: ["flowControl"]` ב-EndpointPickerConfig | נדרש כדי שמטריקת ה-queue תתמלא (בשתי הגרסאות). |
| **פס לוג של Flow Control** | `Flow Control enabled` | `Initializing experimental Flow Control layer` | רק מחרוזת הלוג שונה; הפונקציונליות זהה. |

> **איך לדעת באיזה מודל auth אתה?** פשוט תבדוק: `curl -s -o /dev/null -w "%{http_code}" localhost:19090/metrics`
> בלי טוקן. `200` → מודל פתוח (0.7.x-style, דלג על §3-RBAC). `401` → מודל מוגן (0.8.x, בצע §3 במלואו).

---

## הארכיטקטורה המשותפת (זהה בשתי הגרסאות)

```
EPP /metrics (:9090)  ──scrape──▶  Prometheus  ──PromQL──▶  KEDA prometheus scaler
                                                                     │ רושם external metric
                                                                     ▼
                                              external.metrics.k8s.io  ──▶  HPA (ש-KEDA יוצר ומחזיק)
                                                                                     │ desired = ceil(value/threshold)
                                                                                     ▼
                                                    Deployment  qwen-...-decode  (spec.replicas 1⇄2)
```
נוסחת ההחלטה של ה-HPA (עם `metricType: AverageValue`, שהוא ברירת המחדל של KEDA):
```
רפליקות רצויות = ceil( ערך_השאילתה / threshold )   →   נחתך לטווח [minReplicaCount, maxReplicaCount]
כשיש כמה triggers — ה-HPA לוקח את המקסימום בין ההחלטות של כולם.
```

---

# חלק א' — הפעלת Tracing (OTel + Jaeger)

קבצי ההתקנה נמצאים ב-repo (הותקנו עם `kubectl apply`, לא Helm):

| רכיב | קובץ | מה בפנים |
|---|---|---|
| OTel Collector | `guides/recipes/observability/tracing/otel-collector.yaml` | ConfigMap `otel-collector-config` + Deployment + Service `otel-collector` |
| Jaeger | `guides/recipes/observability/tracing/jaeger-all-in-one.yaml` | Deployment `jaeger` + Service `jaeger-collector` |
| (חלופה) operator | `guides/recipes/observability/tracing/otel-collector-operator.yaml` | לא בשימוש כאן |

### שלב 1 — התקן Jaeger ו-OTel Collector
```bash
cd /home/etty/my-pro/llm-d
kubectl apply -f guides/recipes/observability/tracing/jaeger-all-in-one.yaml
kubectl apply -f guides/recipes/observability/tracing/otel-collector.yaml
kubectl rollout status deploy/jaeger        -n default
kubectl rollout status deploy/otel-collector -n default
```

### שלב 2 — הפעל tracing ב-EPP (דרך ה-Helm values)
ב-`own/all-values.yaml`, תחת `inferenceExtension`, זה כבר מוגדר אצלך:
```yaml
inferenceExtension:
  tracing:
    enabled: true
    otelExporterEndpoint: http://otel-collector:4317
    sampling:
      sampler: parentbased_traceidratio
      samplerArg: "1.0"        # 1.0 = דוגם 100% מה-traces (טוב לדמו; הורד בפרודקשן)
```
החל את השינוי (אם ערכת משהו):
```bash
helm upgrade optimized-baseline <chart> -f own/all-values.yaml -n default
```

### שלב 3 — ודא ש-tracing עובד
```bash
# ה-EPP מייצא ל-otel-collector:4317; Prometheus סורק span-metrics מ-otel-collector:8889 ו-jaeger:8888
kubectl logs deploy/otel-collector -n default | tail
# UI של Jaeger:
kubectl port-forward -n default svc/jaeger-collector 16686:16686
#  → פתח http://localhost:16686 , שלח בקשה דרך ה-gateway, וחפש traces של ה-EPP
```
Prometheus כבר מוגדר לסרוק את השניים (jobs `otel-spanmetrics` ו-`jaeger` ב-`own/prometheus.yml`).

---

# חלק ב' — Prometheus שסורק את ה-EPP (דרוש לשתי גרסאות ה-autoscaling)

ה-Prometheus שלך הוא **רגיל** (לא Prometheus Operator — אין CRD של ServiceMonitor). לכן במקום
ServiceMonitor אנחנו מוסיפים **scrape job סטטי**. זה שונה מהמדריך הרשמי שמניח Operator+ServiceMonitor.

הקובץ `own/prometheus.yml` (כבר קיים אצלך) — ה-job הרלוונטי:
```yaml
- job_name: epp-metrics
  scheme: http
  authorization:                                   # ← נדרש רק ב-0.8.x (מודל מוגן). ב-0.7.x פתוח: מחק את הבלוק הזה.
    type: Bearer
    credentials_file: /var/run/secrets/kubernetes.io/serviceaccount/token
  static_configs:
    - targets: ['optimized-baseline-epp:9090']
```
החלה + reload (ל-Prometheus הזה אין hot-reload, אז restart):
```bash
kubectl create configmap prometheus-config -n default \
  --from-file=prometheus.yml=own/prometheus.yml --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deploy/prometheus -n default
kubectl rollout status  deploy/prometheus -n default
```
אימות שה-target למעלה ושהמטריקות נכנסו:
```bash
kubectl port-forward -n default svc/prometheus 19091:9090 &
curl -s 'localhost:19091/api/v1/targets?state=active' | grep -o '"job":"epp-metrics"[^}]*"health":"[a-z]*"'
curl -s 'localhost:19091/api/v1/query?query=inference_pool_average_running_requests'
```

---

# חלק ג' — Autoscaling על **0.7.x**

בגרסת 0.7.x ה-endpoint של המטריקות לרוב **פתוח** (בדוק עם ה-curl מ"מפת ההבדלים"). לכן:

### מה לעשות (0.7.x)
1. **Tracing** — חלק א' (זהה).
2. **Prometheus scrape** — חלק ב', אבל **מחק את בלוק ה-`authorization`** מה-job (אין צורך בטוקן).
   → **אין צורך ב-`own/metrics-rbac.yaml`** בכלל בגרסה זו.
3. **קרא שמות מטריקות חי** (כלל הזהב). סביר שתקבל את סכימת ה-`inference_*`.
4. **ScaledObject** — זהה ל-§חלק ה' למטה, עם אותם queries. השתמש ב-`own/scaledobject.yaml`.

### הבדל יחיד מהותי מול 0.8.x
פשוט **דלג על כל שלב ה-RBOC/token** (§3 בחלק ד'). כל השאר זהה לחלוטין.

---

# חלק ד' — Autoscaling על **0.8.x** (מאומת על v0.8.0)

כאן `/metrics` **מוגן**: `curl` בלי טוקן מחזיר **401**. צריך שני grants של RBAC + טוקן. זה כל
ההבדל התפעולי מ-0.7.x.

### שלב 1 — Tracing → חלק א'.

### שלב 2 — Flow Control ב-EPP (כדי שמטריקת ה-queue תעבוד)
ב-`own/all-values.yaml`, בתוך ה-`pluginsCustomConfig` → `EndpointPickerConfig`:
```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha1
kind: EndpointPickerConfig
featureGates:
  - "flowControl"          # ← זה מפעיל את שכבת ה-Flow Control (מטריקת queue)
plugins: ...
```
אימות:
```bash
kubectl logs deploy/optimized-baseline-epp -n default | grep -iE 'Flow Control layer|FlowRegistry initialized'
```

### שלב 3 — RBAC כדי לפתוח את `/metrics` (ההבדל מ-0.7.x!) — `own/metrics-rbac.yaml`
צריך **שני** grants שה-chart לא נותן:
1. **הסורק** (Prometheus רץ כ-SA `default`) צריך `get` על nonResourceURL `/metrics`.
2. **ה-SA של ה-EPP** (`optimized-baseline-epp`) צריך `system:auth-delegator` — אחרת גם עם טוקן תקין
   תקבל `500 "Authentication failed"` (ה-EPP לא יכול לבצע TokenReview).
```bash
kubectl apply -f own/metrics-rbac.yaml
```
אימות שה-endpoint נפתח:
```bash
kubectl port-forward -n default svc/optimized-baseline-epp 19090:9090 &
TOKEN=$(kubectl create token default -n default --duration=1h)
curl -s -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" localhost:19090/metrics
#  401 → grant #1 חסר | 500 → grant #2 חסר | 200 → מצוין
```

### שלב 4 — Prometheus scrape → חלק ב' (עם בלוק ה-`authorization`, כפי שקיים).

### שלב 5 — ScaledObject → חלק ה'.

---

# חלק ה' — ה-ScaledObject (משותף; `own/scaledobject.yaml`)

> **התאמה קריטית לחומרה שלך:** בדיקות עומס הראו שעל פוד vLLM CPU יחיד עם `max_num_seqs` ברירת-מחדל,
> **מטריקת ה-queue נשארת 0** גם ב-20 בקשות במקביל (הכל נכנס ל-batch רץ, אף אחד לא מחכה). הסיגנל
> שבאמת זז הוא **running requests**. לכן הטריגר הראשי = running-requests, וה-queue הוא משני
> (backpressure אמיתי לעומס כבד). ראה §"טריגרים חכמים" למטה ל-TTFT/WAITING.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: qwen-decode-epp
  namespace: default
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: qwen-modelservice-llm-d-modelservice-decode
  minReplicaCount: 1
  maxReplicaCount: 2            # תקרה קשיחה: ~10GB RAM, כל פוד vLLM ~4GB. אל תעלה.
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        scaleUp:   { stabilizationWindowSeconds: 0,  policies: [{type: Pods, value: 1, periodSeconds: 15}] }
        scaleDown: { stabilizationWindowSeconds: 30, policies: [{type: Pods, value: 1, periodSeconds: 15}] }
  triggers:
    - type: prometheus          # ראשי — running requests (הסיגנל שעובד)
      metricType: AverageValue
      metadata:
        serverAddress: http://prometheus.default.svc.cluster.local:9090
        query: inference_pool_average_running_requests{name="optimized-baseline"}
        threshold: "3"
    - type: prometheus          # משני — queue depth (backpressure; רדום בעומס קל)
      metricType: AverageValue
      metadata:
        serverAddress: http://prometheus.default.svc.cluster.local:9090
        query: inference_pool_average_queue_size{name="optimized-baseline"}
        threshold: "1"
```
> **הבדל מהמדריך הרשמי:** הדוגמה ב-repo מכוונת ל-Prometheus עם **TLS+bearer** (kube-prometheus-stack)
> ולכן משתמשת ב-`https://...` וב-`TriggerAuthentication` עם CA. ה-Prometheus שלך הוא **HTTP רגיל
> בתוך הקלאסטר**, אז ה-`serverAddress` הוא `http://prometheus.default.svc:9090` ואין צורך ב-`TriggerAuthentication`.

החלה + אימות:
```bash
kubectl apply -f own/scaledobject.yaml
kubectl get scaledobject qwen-decode-epp -n default            # READY=True
kubectl get hpa keda-hpa-qwen-decode-epp -n default            # KEDA יצר אותו
kubectl get hpa keda-hpa-qwen-decode-epp -n default -o jsonpath='{.status.currentMetrics}'   # לא ריק
```

---

# חלק ו' — הפעלת עומס וצפייה (זהה לשתי הגרסאות)

```bash
# terminal 1
kubectl port-forward -n default svc/llm-d-inference-gateway-istio 18080:80 &
# terminal 2 — צפייה חיה
watch -n2 'kubectl get scaledobject qwen-decode-epp -n default; echo; \
kubectl get hpa keda-hpa-qwen-decode-epp -n default; echo; \
kubectl get pods -n default | grep decode'
# terminal 3 — עומס
for i in $(seq 1 12); do
  curl -s -m 120 localhost:18080/v1/completions -H 'Content-Type: application/json' \
    -d '{"model":"qwen-0.5b","prompt":"Write a very long detailed epic story:","max_tokens":512}' >/dev/null &
done
```
מה תראה: `TARGETS` בשורת ה-HPA יעבור מ-`0/3` ל-`10/3` וה-`REPLICAS` יעלה 1→2. אירוע ה-HPA:
```
SuccessfulRescale  New size: 2; reason: external metric s0-prometheus above target
```
**הפוד השני יהיה `Pending / Insufficient memory`** — זה **צפוי ותקין** על ~10GB RAM. מה שחשוב הוא
שההחלטה לסקייל-אפ התקבלה ונראית. כשהעומס נעצר → המטריקה יורדת → ה-HPA מוריד 2→1 ומוחק את הפוד ה-Pending.

---

# חלק ז' — טריגרים "חכמים" (TTFT ו-WAITING) — אופציונלי

אם תרצה לסקייל לפי **סבל אמיתי של המשתמש** ולא רק ספירת בקשות, אלה מגיעים מ-**vLLM עצמו** (לא ה-EPP),
אז צריך scrape job נוסף שסורק את פודי ה-decode (label `llm-d.ai/role=decode`, port 8000, בלי auth).

מטריקות רלוונטיות (מאומתות חי):
| מטריקה | משמעות | האם זזה על החומרה שלך? |
|---|---|---|
| `vllm:time_to_first_token_seconds` (histogram) | TTFT — זמן לטוקן ראשון | **כן, חזק:** ~0.2ש' idle → **~21ש'** ב-20 במקביל |
| `vllm:num_requests_waiting` (gauge) | בקשות שמחכות בתור של vLLM | **לא** — נשאר 0 (ברירת מחדל `max_num_seqs` גבוהה מדי) |

**כדי ש-WAITING יהפוך לסיגנל חי** צריך להכריח את vLLM לתור: הוסף `--max-num-seqs=4` ל-args של פוד
ה-decode (ב-`own/deploy.yaml`), ואז בקשה 5+ במקביל תמתין. עלות: restart של vLLM (~100ש' cold start).

**טריגר TTFT** (עובד בלי שינוי כלל): שאילתת PromQL שמחזירה TTFT ממוצע על חלון, עם `or vector(0)`
כדי להחזיר 0 ב-idle:
```yaml
- type: prometheus
  name: vllm-ttft
  metricType: AverageValue
  metadata:
    serverAddress: http://prometheus.default.svc.cluster.local:9090
    query: >-
      (rate(vllm:time_to_first_token_seconds_sum{model_name="qwen-0.5b"}[1m])
       / rate(vllm:time_to_first_token_seconds_count{model_name="qwen-0.5b"}[1m])) or vector(0)
    threshold: "2"        # TTFT ממוצע מעל 2 שניות → הוסף רפליקה
```
(השארתי את זה כאופציה מתועדת; אם תרצה — נחווט את ה-scrape של vLLM ונוסיף את הטריגר.)

---

# חלק ח' — Cleanup

```bash
kubectl delete -f own/scaledobject.yaml     # מוחק ScaledObject; KEDA מוחק את ה-HPA אוטומטית
# רק אם רוצים להחזיר את הכל אחורה:
kubectl delete -f own/metrics-rbac.yaml      # נועל מחדש את /metrics מסריקה (0.8.x בלבד)
# להסרת ה-scrape של EPP: החזר את own/prometheus.yml ל-otel+jaeger בלבד, apply configmap, restart
```

---

# Gotchas (מכל מה שנתקלנו בו)

- **"המטריקה נעלמה"** ב-0.8.x = בעצם **401**, לא שינוי שם. השמות של 0.7.0 זהים. תקן: RBAC (§ד'-3).
- **`500 Authentication failed`** אחרי הוספת grant הסורק = חסר `system:auth-delegator` ל-SA של ה-EPP.
- **queue נשאר 0** בעומס קל — פוד CPU יחיד קולט הכל ל-batch. סקייל על running-requests, לא queue.
- **`inference_pool_average_running_requests` בפיגור ~15ש'** (זה EMA). לתגובה מהירה יותר אפשר
  `inference_objective_running_requests{model_name="qwen-0.5b"}`.
- **הפוד השני Pending** על ~10GB RAM — צפוי. `maxReplicaCount: 2` תקרה קשיחה, אל תעלה.
- **Cold start ~100ש'** → `minReplicaCount: 1` (לא לסקייל לאפס).
- **שגיאה שפירה בלוגים של EPP:** `extract failed ... metric family "vllm:lora_requests_info" not found`
  — המודל בלי LoRA, אז vLLM לא מייצא את המטריקה הזו, וה-extractor מתלונן. **לא משפיע** על כלום. התעלם.
- **ל-Prometheus הזה אין hot-reload** → `rollout restart` אחרי עריכת ה-ConfigMap.
- **ה-service `vllm` (port 8000) הוא leftover מת** — selector `app=vllm` לא תופס כלום. פודי ה-decode
  מסומנים `llm-d.ai/role=decode`. אם תסרוק vLLM — סרוק את הפודים ישירות, לא את ה-service.
