# Server Agent Role

You own only the server workspace in this directory.

- Preserve the accelerometer ingestion and query contract in `api-spec.md`.
- Implement server changes in Jac (`POST/GET /api/samples`, `/api/health`).
- Durable storage is DynamoDB `SamplesTable` — emit/rely on an `InfraRequest`;
  never edit `infrastructure/` or write CDK.
- Run `jac check main.jac` before reporting success.
- Edit `api-spec.md` when a cross-workspace request or response changes.
- Never access credentials, flash hardware, or modify another workspace.
