# Transfer Scenarios Overview

| Source | Destination | Intermediary needed? |
|--------|-------------|----------------------|
| WebDAV | WebDAV | No — TPC native (StoRM/dCache/XrdHTTP) |
| S3 | WebDAV | No — WebDAV pulls from S3 via pre-signed URL |
| XrdHTTP | WebDAV | No — HTTP TPC (same as WebDAV) |
| WebDAV | S3 | Yes — standard S3 cannot act as TPC destination (needs FTS or gateway) |
| XrdHTTP | S3 | Yes — requires FTS or TPC-capable S3 gateway |
| S3 | S3 | Yes — FTS streaming (or native S3 replication outside FTS) |
| S3 | XrdHTTP | Depends — no intermediary if XrdHTTP endpoint can pull from S3 |
| XrdHTTP | XrdHTTP | No — native HTTP TPC supported |
| XRootD (native root://) | anything | Depends — native TPC if supported, otherwise FTS fallback |

**NOTE:**
- Third-Party Copy (TPC) transfers data directly between storage endpoints, avoiding
  FTS in the data path. The **destination** storage initiates the transfer by pulling
  from the source. Not all storage systems support acting as a TPC destination.
- Intermediary (streaming) transfers route data through FTS, which can introduce
  additional network load and potential bottlenecks when TPC is not supported.