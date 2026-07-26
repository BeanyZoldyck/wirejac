import * as cdk from 'aws-cdk-lib/core';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';
import { MetaAppHosting } from './meta-app-hosting';
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
    new SamplesTable(this, 'SamplesTable');

    // Fulfilled InfraRequest: MetaAppHosting (kind=frontend_hosting).
    // Static UI only — API + DynamoDB stay on the Jac server path.
    new MetaAppHosting(this, 'MetaAppHosting');
  }
}
