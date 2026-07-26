# Wirejac AWS infrastructure

This directory contains the AWS CDK v2 application for the Wirejac hackathon
development environment.

## Current deployment

- Stack: `WirejacDevStack`
- Account: `852353855241`
- Region: `us-west-2`
- Profile: `wirejac`
- Marker parameter: `/wirejac/dev/stack-status`

The stack currently contains:

- SSM deployment marker `/wirejac/dev/stack-status`
- DynamoDB `wirejac-samples` (`SamplesTable`) for accelerometer history
- SSM parameter `/wirejac/dev/samples-table-name` exporting the table name
- S3 + CloudFront Meta app hosting (`MetaAppHosting`) for `workspace/client`
- SSM parameter `/wirejac/dev/meta-app-url` exporting the CloudFront URL

After deploy, point the server at the table:

```sh
export WIREJAC_SAMPLES_TABLE=wirejac-samples
export WIREJAC_AWS_REGION=us-west-2
export WIREJAC_AWS_PROFILE=wirejac
```

## Meta app (product UI)

`workspace/client` is uploaded to a private S3 bucket and served over HTTPS
via CloudFront on each `cdk deploy`. Stack outputs:

- `MetaAppUrl` — open this in a browser
- `MetaAppBucketName` — bucket holding the static assets

The Meta app does **not** call DynamoDB from the browser. It should call the
Jac sample API (`GET /api/samples`). That API reads DynamoDB when
`WIREJAC_SAMPLES_TABLE` is set.

CORS: single-process `jac start` allows all origins (`*`), so a CloudFront
page can call a Jac API on another host without extra CORS config. Point the
client at your API base URL (for example `http://localhost:8000` while the
server runs locally).

## Authentication

Authenticate through AWS's browser login. Do not place passwords, access keys,
or session tokens in this repository.

```sh
aws login --profile wirejac
aws sts get-caller-identity --profile wirejac
```

## Workflow

```sh
npm install
npm run build
npm test -- --runInBand
npx cdk synth WirejacDevStack --profile wirejac
npx cdk diff WirejacDevStack --profile wirejac
npx cdk deploy WirejacDevStack --profile wirejac
```

Run `cdk diff` and review the proposed change before every deployment.

To remove the development stack when the hackathon is over:

```sh
npx cdk destroy WirejacDevStack --profile wirejac
```
