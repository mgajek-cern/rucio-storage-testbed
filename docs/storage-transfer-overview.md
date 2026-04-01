# Transfer Scenarios Overview

| Scenario | Intermediary needed? |
|---|---|
| WebDAV ↔ WebDAV | No — TPC native (StoRM/dCache/XrdHttp) |
| WebDAV ↔ S3 | No — WebDAV can push/pull from S3 directly (TPC feasible) |
| S3 ↔ S3 | Yes — FTS streaming required |
| XRootD (XrdHTTP) ↔ WebDAV | No — same as WebDAV TPC |
| XRootD (XrdHTTP) ↔ S3 | No — same as WebDAV TPC if XrdHTTP enabled |
| XRootD (native root://) ↔ anything | Depends — FTS needed if TPC not supported |
| S3 ↔ XRootD | Yes — FTS or gateway |

**NOTE:**
- Mapping table abve verified in sync with Rucio/FTS maintainers
- Third-Party Copy (TPC) transfers data directly between storage endpoints, avoiding FTS in the data path. In contrast, intermediary (streaming) transfers route data through FTS, which can introduce additional network load and potential bottlenecks when TPC is not supported or possible.
