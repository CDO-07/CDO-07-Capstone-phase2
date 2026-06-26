# Requirements Analysis - Task Force 4 · CDO-07

## 1. Đề tài context

Hệ thống giám sát và dự báo chủ động **Foresight Lens** được thiết kế để giải quyết bài toán vận hành thực tế cho một khách hàng Fintech quy mô tầm trung. Hiện tại, doanh nghiệp đang phục vụ khoảng 3.5 triệu người dùng hoạt động (active users), với mức tải ngày thường đạt 2.8k Requests Per Second (RPS) và đạt đỉnh (peak traffic) lên tới 9k RPS trong các sự kiện lớn như Black Friday. Toàn bộ hệ thống core-banking và tài chính phụ trợ đang vận hành thông qua cụm hạ tầng gồm hơn 120 microservices production triển khai trên nền tảng AWS ECS Fargate, kết hợp với các CSDL RDS Aurora MySQL, DynamoDB và hệ thống hàng đợi SQS.

### Vấn đề cốt lõi của khách hàng
Trong vòng 3 tháng vừa qua, đội ngũ SRE (Site Reliability Engineering) của doanh nghiệp đã làm giảm uy tín thương hiệu khi vi phạm chỉ số SLO cam kết về độ sẵn sàng của hệ thống (Monthly Availability Target 99.9%) trong 7 lần liên tiếp. Đáng chú ý, nguyên nhân không xuất phát từ các sự cố sập nguồn thảm họa (catastrophic incidents), mà lại đến từ các lỗi cạn kiệt tài nguyên âm thầm (capacity exhaustion silent) diễn ra từ từ theo thời gian:
* CPU của các cụm cơ sở dữ liệu RDS Aurora MySQL tăng dần đều và neo giữ ở mức 100% suốt 90 phút trước khi làm nghẽn hoàn toàn kết nối (connection pool exhaustion).
* Lượng tin nhắn tồn đọng (backlog) trong hệ thống hàng đợi SQS tích tụ âm thầm lên gấp 6 lần khiến các ứng dụng tiêu thụ dữ liệu (consumers) rơi vào trạng thái timeout.
* Giới hạn kết nối (connection limit) trên Application Load Balancer (ALB) chạm ngưỡng trần mỗi khi có traffic spike vào cuối tuần.

Tất cả các sự cố trên đều bị phát hiện muộn sau khi có từ 18 đến 25 khiếu nại (support tickets) từ phía người dùng cuối phản hồi về bộ phận CS, thay vì được phát hiện chủ động từ hệ thống giám sát nội bộ. Khách hàng đã có sẵn các dashboard CloudWatch và DataDog, nhưng họ thiếu một giải pháp tự động hóa có khả năng học baseline động thay vì dựa vào các ngưỡng cấu hình tĩnh (static thresholds) dễ gây nhiễu alert (alert fatigue) hoặc bỏ sót các biến động chậm (slow drift).

### Mục tiêu của Foresight Lens
Xây dựng một hệ thống phân tích và dự báo chuỗi thời gian (time-series metrics) hoạt động liên tục 24/7 để:
1. Tự động thu thập và phân tích các chỉ số tài nguyên từ 3 dịch vụ Tier-1 cốt lõi.
2. Học tập hành vi bình thường (per-service baseline) theo chu kỳ tuần để nhận diện tính chất mùa vụ của ngành tài chính.
3. Chủ động phát tín hiệu cảnh báo (proactive ping) trước ít nhất 15 phút khi hệ thống có dấu hiệu drift hoặc sắp cạn kiệt tài nguyên (capacity exhaustion).
4. Đưa ra các khuyến nghị hành động cụ thể (Actionable Capacity Recommendation) có cấu trúc tường minh để kỹ sư SRE phê duyệt bằng tay (manual approval gate).

---

## 2. Infra non-functional requirements

Để hệ thống Foresight Lens hoạt động ổn định và đáp ứng các tiêu chuẩn khắt khe của một hệ thống tài chính, hạ tầng do nhóm CDO triển khai phải cam kết đạt được các chỉ số phi chức năng sau đây:

| Chỉ số NFR | Ngưỡng Mục tiêu (Target) | Khung Lý do & Ràng buộc Kỹ thuật (Justification) |
| :--- | :--- | :--- |
| **Multi-tenant scale** | ≥ 3 tenant được thiết kế để đóng gói thành sản phẩm thương mại hóa (SaaS), cho phép quản lý và cô lập dữ liệu metric từ tối thiểu 3 tenant khác nhau. |
| **SLO p99 latency** | < 500ms | Áp dụng nghiêm ngặt cho điểm cuối API `/v1/predict`. Thời gian xử lý từ lúc nhận payload time-series window đến khi trả về kết quả dự báo không được quá 1 giây để bảo toàn thời gian xử lý sự cố. |
| **Availability** | ≥ 99.5% | Cam kết độ sẵn sàng ổn định cho toàn bộ pipeline ingestion và hệ thống lưu trữ dữ liệu giám sát cốt lõi, đảm bảo không làm đứt gãy luồng metric truyền về. |
| **Error rate** | < 0.5% | Tỷ lệ lỗi sinh ra trên đường truyền dẫn dữ liệu (drop metric, network error) phải được kiểm soát dưới 0.5% để tránh làm sai lệch tập dữ liệu đầu vào của mô hình AI. |
| **Cost per tenant/month** | ~$59.97/ tenant | Dựa trên mục tiêu phân bổ ngân sách tối ưu của dự án, 179 đô cho 3 tenant |
| **Onboarding SLA** | < 30 phút | Thời gian từ lúc một microservice mới triển khai cấu hình endpoint `/metrics` công khai cho đến khi ADOT Collector tự động scrape và AMP sẵn sàng định danh label mới. |
| **Security baseline** | IAM least-privilege + audit 90 ngày | Toàn bộ tiến trình ADOT thu thập và đẩy metric sử dụng AWS SigV4 định danh IAM Roles chặt chẽ. Dữ liệu metric lưu trên AMP được mã hóa tại chỗ (Encryption at rest) và lưu audit log truy cập API tại S3 Glacier với vòng đời 90 ngày. |

---

## 3. Differentiation Angle (KEY)

Sau khi nghiên cứu sâu sắc về bản chất bài toán và các rủi ro kỹ thuật liên quan đến độ trễ dữ liệu và chi phí, nhóm quyết định lựa chọn hướng kiến trúc làm điểm nhấn cạnh tranh độc quyền:

* **Angle lựa chọn:** `Prometheus-Centric Native Observability (ADOT Collector + Amazon Managed Prometheus - AMP)`.
* **Why this angle (Trục chiến thắng - Win Axis):** Khách hàng yêu cầu một hệ thống có khả năng đưa ra dự báo với *Lead time ≥ 15 phút* trước khi xảy ra vi phạm SLO. Để làm được điều này, dữ liệu đầu vào của AI Engine phải là dữ liệu "tươi nhất" (Real-time granularity) và giữ nguyên độ phân giải mịn trong suốt thời gian lưu trữ lịch sử để học được các dịch chuyển chậm (*slow drift*).
    * **Real-time Scrape & Không độ trễ:** Thay vì chịu độ trễ gom lô (batching latency) lớn của các giải pháp Lakehouse (Option B) qua Firehose/Glue Job, mô hình ADOT Collector chạy sidecar trực tiếp kéo metrics (`pull/scrape mechanism`) từ container và truyền phát tức thì qua Remote Write (SigV4) về AMP. AI Engine có thể thực hiện truy vấn PromQL với độ trễ mili-giây, cung cấp cửa sổ vàng dữ liệu thời gian thực cho mô hình.
    * **Native Multi-tenancy qua Prometheus Labels:** Thay vì thiết kế các bảng CSDL phân tách phức tạp, AMP cho phép cô lập dữ liệu hiệu quả cao ngay trên 1 Workspace duy nhất bằng cách tận dụng các cặp nhãn cốt lõi: `tenant_id`, `service_id`, và `metric_type`.
    * **Lưu trữ thô nguyên bản (No Down-sampling):** Tránh được rủi ro bị nén dữ liệu mất chi tiết sau 15 ngày của CloudWatch Custom Metrics (Option C). Hệ thống AMP mặc định duy trì retention lên tới **150 ngày** với độ mịn thô nguyên bản tuyệt đối, giúp AI Engine dễ dàng nhận diện tính mùa vụ và học baseline động chuẩn xác.

### Phân tích Chi phí & Biến động giữa các Option Architectural

Để làm rõ tính khả thi của Option A dưới áp lực tải lớn trong ngân sách giới hạn **$200/tháng (Circuit Breaker Cap)**, nhóm thực hiện lập bảng đối chiếu cấu trúc chi phí (Cost Profile) chi tiết từ tầng nạp dữ liệu (Ingestion) đến tầng lưu trữ/truy vấn của AI:

| Tiêu chí | Option A: Prometheus-Centric (Lựa chọn của nhóm) | Option B: Lakehouse (S3 + Glue + Athena) | Option C: Managed Observability (CloudWatch Metrics) |
| :--- | :--- | :--- | :--- |
| **Cơ chế tính phí chính** | • **AMP**: Tính phí theo số lượng mẫu nạp vào (*Metric Samples Ingested*), dung lượng lưu trữ ($/GB-tháng) và số lượng mẫu được quét qua câu lệnh truy vấn PromQL (*Query Samples Processed*).<br>• **ADOT**: Biến phí rất nhỏ dựa trên mức tiêu thụ tài nguyên phần cứng (CPU/RAM) khi chạy Sidecar. | • Phí nạp dữ liệu qua Kinesis Firehose.<br>• Phí lưu trữ S3.<br>• Phí quét dữ liệu của Amazon Athena ($5/TB). | Phí nạp Custom Metrics theo số lượng Metric Volume ($0.30/metric/tháng cho 10k metrics đầu). |
| **Chi phí cố định (Fixed Cost)** | **Rất thấp (~$0 - $5)**: Không tốn phí duy trì Shard cố định như Kinesis. Hoàn toàn phụ thuộc vào lượng metric phát sinh thực tế. Tài nguyên cho ADOT Sidecar container cực kỳ gọn nhẹ. | **Trung bình - Cao**: Chi phí chạy Glue Job định kỳ để nén/partition dữ liệu (tối thiểu ~0.44$/DPU-Hour). | **Rất cao (Vượt Budget)**: Với 120 services × trung bình 5 metrics/service = 600 metrics × 50k events/sec sẽ làm bùng nổ (*explode*) chi phí Custom Metrics vượt xa mức $200. |
| **Rủi ro chi phí biến đổi (Variable Risk)** | **Trung bình - Cao**: 1. *Tầng Ingestion*: Nguy cơ bùng nổ chi phí nạp nếu cấu hình các nhãn có độ biến động giá trị quá cao (*High-Cardinality Explosion*).<br>2. *Tầng Query*: AI Engine gọi câu lệnh PromQL quá dày đặc hoặc quét diện rộng trên toàn bộ Workspace gây lặp dữ liệu xử lý. | **Thấp - Trung bình**: Nếu dữ liệu trên S3 được partition tốt bằng Glue, chi phí quét của Athena rất rẻ. Phí Firehose nạp vào thấp. | **Thấp**: Chi phí cố định theo số lượng metric được cấu hình trước từ đầu. |
| **Giải pháp kiểm soát (Mitigation)** | **Lọc tại nguồn & Giới hạn cửa sổ truy vấn**: <br>1. **Cho ADOT**: Cấu hình `ADOT Processor` để thực hiện *Filtering & Batching* chủ động drop các nhãn/chỉ số dư thừa trước khi Remote Write.<br>2. **Cho AMP**: Ép AI Engine sử dụng PromQL có điều kiện filter nghiêm ngặt theo thời gian (ví dụ: `[2h]`), giới hạn tần suất quét định kỳ (mỗi 5 phút) để tối ưu hóa *Query Samples Processed*. | *Không áp dụng* vì đã bị loại do **Độ trễ lớn (Batching Latency)** từ cơ chế gom lô của Kinesis Firehose và tiến trình lên lịch của AWS Glue Job → không đáp ứng được Lead time ≥ 15 phút. | *Không áp dụng* vì bị loại do rủi ro **Data Down-sampling** (tự động nén dữ liệu, mất độ phân giải mịn sau 15 ngày → AI không học được các chi tiết dịch chuyển chậm - slow drift). |

* **Trade-off chấp nhận:** Để đổi lấy hệ thống quan sát chuẩn hóa mã nguồn mở, độ phân giải dữ liệu hoàn hảo lưu trữ trọn vẹn lên tới 150 ngày và tốc độ truy vấn tức thời phục vụ AI Engine, nhóm chấp nhận chia sẻ một phần nhỏ tài nguyên tính toán của ECS Fargate cho **ADOT Sidecar container** (0.25 vCPU & 0.5GB RAM per task). Đồng thời, nhóm chấp nhận kiểm soát chặt chẽ thiết kế nhãn (Metric Labels) để triệt tiêu hoàn toàn rủi ro bùng nổ nhãn (*High-Cardinality*) làm tăng vọt chi phí nạp của AMP. 
Nhóm thiết lập chính sách giới hạn quét nghiêm ngặt trên câu lệnh PromQL của Lambda Window Feeder (quét đúng cửa sổ 2 giờ và kích hoạt định kỳ 5 phút). Điều này đảm bảo hệ thống vừa giữ vững mục tiêu kỹ thuật nghiêm ngặt (FP ≤ 12%, Catch ≥ 80% drift), vừa kiểm soát tổng chi phí vận hành thực tế nằm trọn vẹn trong mức giới hạn circuit breaker $200/tháng đề ra.

---

## 4. Constraints

- **AWS only** – Không triển khai multi-cloud, chỉ sử dụng các dịch vụ AWS.
- **Region** – `us-east-1` (North Virginia) cho toàn bộ môi trường triển khai.
- **Budget cap** – ≤ $200/tháng cho solution capstone.
- **Single-region deployment** – Không triển khai multi-region, Disaster Recovery chỉ ở mức thiết kế.
- **Auto-remediation** – Không nằm trong phạm vi dự án; hệ thống chỉ thực hiện prediction và recommendation.
- **Auto-retraining pipeline** – Không xây dựng trong capstone; chỉ mô tả trigger logic thông qua ADR.
- **Infrastructure metrics only** – Chỉ xử lý metrics hạ tầng (CPU, Memory, Queue Depth, Connections, Latency), không xử lý business metrics hoặc dữ liệu PII.
- **Synthetic workload only** – Không sử dụng production traffic; kiểm thử bằng k6/Locust và dữ liệu mô phỏng.
- **LLM-based prediction** – Không sử dụng do chi phí cao; tập trung vào statistical/ML-based forecasting.
- **Code freeze** : Đóng băng code vào 08:00 AM ngày 02/07/2026. Mọi thay đổi sau thời điểm này đều bị từ chối.

---

## 5. Open questions

- [ ] Q1: Tier-1 services nào sẽ được lựa chọn làm baseline services trong giai đoạn capstone?
- [ ] Q2: Tần suất Scrape Interval của ADOT Collector nên đặt ở mức bao nhiêu giây để cân bằng tốt nhất giữa độ nhạy của AI và chi phí nạp Metric Samples của AMP?
- [ ] Q3: Baseline refresh nên thực hiện theo lịch cố định hàng tuần hay dựa trên drift threshold?
- [ ] Q4: Capacity recommendation có yêu cầu approval workflow trước khi gửi SNS notification hay không?
- [ ] Q5: AI Engine sẽ tích hợp Prometheus PromQL Client để gọi trực tiếp vào AMP Secure Endpoint qua cơ chế xác thực SigV4 như thế nào?