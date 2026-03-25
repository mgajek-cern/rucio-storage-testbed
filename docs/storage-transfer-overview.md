# Transfer Scenarios Overview

| Scenario              | Intermediary needed? | Technical Reason                                                               |
|----------------------|---------------------|----------------------------------------------------------------------------------|
| WebDAV ↔ WebDAV      | No                  | Uses HTTP TPC (COPY verb).                                                       |
| XRootD ↔ XRootD      | No / Depends        | Supported via XRootD TPC; FTS is intermediary only if TPC fails.                 |
| S3 ↔ S3              | Depends             | Intermediary-free only if server-side copy is supported by the provider.         |
| WebDAV ↔ XRootD      | Yes                 | Protocol translation requires FTS in the data path.                              |
| WebDAV ↔ S3          | Yes                 | No native cross-protocol TPC.                                                    |
| S3 ↔ XRootD          | Yes                 | Requires FTS or a gateway (like XrdS3) to bridge protocols.                      |

**NOTE:**
Third-Party Copy (TPC) transfers data directly between storage endpoints, avoiding FTS in the data path. In contrast, intermediary (streaming) transfers route data through FTS, which can introduce additional network load and potential bottlenecks when TPC is not supported or possible.