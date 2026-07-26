import * as path from 'node:path';
import * as cdk from 'aws-cdk-lib/core';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

export interface SamplesApiProps {
  readonly table: dynamodb.ITable;
}

/**
 * Cloud sample API (Option A): Lambda Function URL + shared team API key.
 *
 * Laptops never need AWS credentials. Callers send X-Api-Key; the function
 * role holds DynamoDB access. Health stays public for probes.
 */
export class SamplesApi extends Construct {
  public readonly functionUrl: string;
  public readonly apiKeySecret: secretsmanager.Secret;

  constructor(scope: Construct, id: string, props: SamplesApiProps) {
    super(scope, id);

    this.apiKeySecret = new secretsmanager.Secret(this, 'ApiKey', {
      secretName: 'wirejac/dev/samples-api-key',
      description: 'Shared hackathon API key for the Wirejac samples API',
      generateSecretString: {
        passwordLength: 32,
        excludePunctuation: true,
      },
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const fn = new lambda.Function(this, 'Function', {
      functionName: 'wirejac-samples-api',
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset(
        path.join(__dirname, '..', 'lambda', 'samples-api'),
      ),
      timeout: cdk.Duration.seconds(15),
      memorySize: 256,
      environment: {
        WIREJAC_SAMPLES_TABLE: props.table.tableName,
        WIREJAC_AWS_REGION: cdk.Stack.of(this).region,
        WIREJAC_API_KEY: this.apiKeySecret.secretValue.unsafeUnwrap(),
      },
    });

    props.table.grantReadWriteData(fn);

    // Function URL is public; authorization is the shared API key checked in-handler.
    const url = fn.addFunctionUrl({
      authType: lambda.FunctionUrlAuthType.NONE,
      cors: {
        allowedOrigins: ['*'],
        allowedHeaders: ['content-type', 'x-api-key'],
        allowedMethods: [lambda.HttpMethod.GET, lambda.HttpMethod.POST],
      },
    });

    this.functionUrl = url.url;

    new ssm.StringParameter(this, 'ApiUrlParam', {
      parameterName: '/wirejac/dev/samples-api-url',
      stringValue: this.functionUrl,
      description: 'HTTPS URL for the Wirejac samples API (Lambda Function URL)',
      tier: ssm.ParameterTier.STANDARD,
    });

    new ssm.StringParameter(this, 'ApiKeySecretArnParam', {
      parameterName: '/wirejac/dev/samples-api-key-secret-arn',
      stringValue: this.apiKeySecret.secretArn,
      description: 'Secrets Manager ARN for the shared samples API key',
      tier: ssm.ParameterTier.STANDARD,
    });

    new cdk.CfnOutput(this, 'SamplesApiUrl', {
      value: this.functionUrl,
      description: 'Cloud samples API base URL (send X-Api-Key)',
      exportName: 'WirejacSamplesApiUrl',
    });

    new cdk.CfnOutput(this, 'SamplesApiKeySecretArn', {
      value: this.apiKeySecret.secretArn,
      description:
        'Fetch the shared API key: aws secretsmanager get-secret-value --secret-id wirejac/dev/samples-api-key',
      exportName: 'WirejacSamplesApiKeySecretArn',
    });
  }
}
