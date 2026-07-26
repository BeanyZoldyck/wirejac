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
- Lambda Function URL samples API (`SamplesApi`) with IAM → DynamoDB
- Secrets Manager `wirejac/dev/samples-api-key` (shared team API key)
- SSM `/wirejac/dev/samples-api-url` exporting the Function URL
- S3 + CloudFront Meta app hosting (`MetaAppHosting`) for `workspace/client`
- SSM parameter `/wirejac/dev/meta-app-url` exporting the CloudFront URL

## Portable cloud API (Option A)

Anyone at the hackathon can call the samples API without AWS credentials on
their laptop:

1. Deploy once (someone with the `wirejac` profile).
2. Share the Function URL + API key (or open the Meta app — `config.js` is
   injected automatically).
3. Callers send `X-Api-Key`. The Lambda role owns DynamoDB access.

```sh
# After deploy
SAMPLES_API_URL=$(aws ssm get-parameter --name /wirejac/dev/samples-api-url \
  --profile wirejac --query Parameter.Value --output text)
WIREJAC_API_KEY=$(aws secretsmanager get-secret-value \
  --secret-id wirejac/dev/samples-api-key --profile wirejac \
  --query SecretString --output text)

curl "$SAMPLES_API_URL/api/health"
curl -H "X-Api-Key: $WIREJAC_API_KEY" \
  "$SAMPLES_API_URL/api/samples?session_id=training-001"
```

Local Jac parity (optional):

```sh
export WIREJAC_API_KEY=...          # same shared key, or any local value
# omit WIREJAC_SAMPLES_TABLE for in-memory; or set it + profile for local Dynamo
jac start workspace/server/main.jac --no-client
```

## Meta app (product UI)

`workspace/client` is uploaded to a private S3 bucket and served over HTTPS
via CloudFront on each `cdk deploy`. Stack outputs:

- `MetaAppUrl` — open this in a browser
- `MetaAppBucketName` — bucket holding the static assets

Deploy writes `config.js` with `apiBaseUrl` + `apiKey` so the Meta app talks
to `SamplesApi` without committing secrets to git.

## AWS login (deployers only)

Only machines that run `cdk deploy` need AWS browser login. Do not place
passwords, access keys, or session tokens in this repository.

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
