# User Workflows: Rucio DID Creation and Replication

Rucio supports two primary workflows for bringing data under management. The testbed's E2E scripts (`test-rucio-transfers.py`) specifically validate **Workflow B**.

## A) Managed Upload
Files are uploaded through Rucio, which handles both data transfer and metadata registration.
**Use case:** Institutional data ingestion, user-uploaded research data.

```mermaid
sequenceDiagram
    participant User
    participant Rucio
    participant RSE1 as RSE (source)
    participant RSE2 as RSE (destination)

    User->>Rucio: Upload files to RSE1
    Rucio->>RSE1: Upload files
    Rucio->>Rucio: Create DIDs & register replicas (RSE1)

    User->>Rucio: Create dataset & attach files
    Rucio->>Rucio: Create dataset DID & link files

    User->>Rucio: Create replication rule (dataset → RSE2)
    Rucio->>RSE2: Transfer files
    Rucio->>Rucio: Register replicas (RSE2)
```

## B) Manual Registration (Testbed Default)
Files already exist in storage (produced by external workflows). Rucio registers metadata without moving data.
**Use case:** External data spaces (EUCAIM), HPC outputs.

```mermaid
sequenceDiagram
   participant WMS as Workflow System
   participant Rucio
   participant RSE

   WMS->>RSE: Produce files directly on storage
   WMS->>Rucio: Register DID + replica (no data movement)
   Rucio->>Rucio: Create DID & register replica
```

## Key Concepts
- **DID (Data Identifier):** Represents a single logical file or dataset.
- **Replica:** A physical copy of a DID on a specific Rucio Storage Element (RSE).
- **Replication Rules:** Logic that triggers the Rucio-FTS chain to create additional replicas.
