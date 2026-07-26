import * as cdk from 'aws-cdk-lib/core';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { MetaAppHosting } from './meta-app-hosting';
import { SamplesApi } from './samples-api';
import { SamplesTable } from './samples-table';

export class WirejacDevStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    new ssm.StringParameter(this, 'StackStatus', {
      parameterName: '/wirejac/dev/stack-status',
      stringValue: 'ready',
      description: 'Deployment marker for the Wirejac development stack',
      tier: ssm.ParameterTier.STANDARD,
    });

    // Fulfilled InfraRequest: SamplesTable (kind=data), requested by server.
    const samples = new SamplesTable(this, 'SamplesTable');

    // Fulfilled InfraRequest: SamplesApi (kind=backend_runtime).
    // Cloud API + IAM role for DynamoDB; shared team API key for callers.
    const api = new SamplesApi(this, 'SamplesApi', {
      table: samples.table,
    });

    // Fulfilled InfraRequest: MetaAppHosting (kind=frontend_hosting).
    // Static UI; config.js points at SamplesApi with the shared key.
    new MetaAppHosting(this, 'MetaAppHosting', {
      samplesApiUrl: api.functionUrl,
      samplesApiKeySecret: api.apiKeySecret,
    });
  }
}
