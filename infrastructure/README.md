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

After deploy, point the server at the table:

```sh
export WIREJAC_SAMPLES_TABLE=wirejac-samples
export WIREJAC_AWS_REGION=us-west-2
export WIREJAC_AWS_PROFILE=wirejac
```

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
