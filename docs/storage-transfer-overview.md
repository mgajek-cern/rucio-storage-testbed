# Transfer Scenarios Overview

| Scenario | Intermediary needed? | Technical Reason |
|---|---|---|
| WebDAV ↔ WebDAV | No / Depends | Supported via WLCG HTTP TPC (COPY with Source header) on specialized servers (StoRM, dCache, XrdHttp). Intermediary needed if using standard mod_dav. |
| XRootD ↔ XRootD | No / Depends | Supported via native XRootD TPC; FTS is intermediary only if TPC fails or is disabled. |
| S3 ↔ S3 | Depends | Intermediary-free only if server-side copy is supported by the provider (typically within the same region/account). |
| WebDAV ↔ XRootD | No / Depends | If XRootD has XrdHttp enabled, it uses WebDAV TPC. If strictly root:// vs https://, an intermediary (FTS) is required for translation. |
| WebDAV ↔ S3 | Yes | No native cross-protocol TPC exists; requires FTS or a specialized gateway to bridge protocols. |
| S3 ↔ XRootD | Yes | Requires FTS or a gateway (like XrdS3) to bridge protocols. |

**NOTE:**
Third-Party Copy (TPC) transfers data directly between storage endpoints, avoiding FTS in the data path. In contrast, intermediary (streaming) transfers route data through FTS, which can introduce additional network load and potential bottlenecks when TPC is not supported or possible.
