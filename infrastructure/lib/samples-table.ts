import * as cdk from 'aws-cdk-lib/core';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

/**
 * Durable store for accelerometer samples.
 *
 * Owned by the infrastructure worker. Application (server) code must not
 * define this table — it consumes the name via WIREJAC_SAMPLES_TABLE / SSM.
 */
export class SamplesTable extends Construct {
  public readonly table: dynamodb.Table;

  constructor(scope: Construct, id: string) {
    super(scope, id);

    const tableName = 'wirejac-samples';

    this.table = new dynamodb.Table(this, 'Table', {
      tableName,
      partitionKey: {
        name: 'session_id',
        type: dynamodb.AttributeType.STRING,
      },
      sortKey: {
        name: 'sample_id',
        type: dynamodb.AttributeType.STRING,
      },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      pointInTimeRecoverySpecification: {
        pointInTimeRecoveryEnabled: false,
      },
    });

    new ssm.StringParameter(this, 'TableNameParam', {
      parameterName: '/wirejac/dev/samples-table-name',
      // Literal name (not a CFN Ref) so operators can export it before deploy settles.
      stringValue: tableName,
      description: 'DynamoDB table name for Wirejac accelerometer samples',
      tier: ssm.ParameterTier.STANDARD,
    });

    new cdk.CfnOutput(this, 'SamplesTableName', {
      value: tableName,
      description: 'Set WIREJAC_SAMPLES_TABLE to this value for the server',
      exportName: 'WirejacSamplesTableName',
    });
  }
}
