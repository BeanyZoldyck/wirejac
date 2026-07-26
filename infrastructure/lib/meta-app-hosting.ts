import * as path from 'node:path';
import * as cdk from 'aws-cdk-lib/core';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as cr from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';

export interface MetaAppHostingProps {
  /** Cloud samples API base URL (Lambda Function URL). */
  readonly samplesApiUrl?: string;
  /** Shared team API key secret (resolved at deploy by WriteConfig Lambda). */
  readonly samplesApiKeySecret?: secretsmanager.ISecret;
}

/**
 * Static hosting for the Meta app (accelerometer product UI in workspace/client).
 *
 * The browser never talks to DynamoDB. It calls the cloud samples API
 * (GET /api/samples) with X-Api-Key. config.js is written by a small Lambda
 * that reads Secrets Manager — BucketDeployment cannot resolve secrets into
 * file bodies.
 */
export class MetaAppHosting extends Construct {
  public readonly bucket: s3.Bucket;
  public readonly distribution: cloudfront.Distribution;
  public readonly url: string;

  constructor(scope: Construct, id: string, props: MetaAppHostingProps = {}) {
    super(scope, id);

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: undefined, // let CloudFormation assign a unique name
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      versioned: false,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    this.distribution = new cloudfront.Distribution(this, 'Distribution', {
      comment: 'Wirejac Meta app (accelerometer dashboard)',
      defaultRootObject: 'index.html',
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(this.bucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD_OPTIONS,
        cachedMethods: cloudfront.CachedMethods.CACHE_GET_HEAD_OPTIONS,
        compress: true,
      },
      errorResponses: [
        {
          httpStatus: 404,
          responseHttpStatus: 200,
          responsePagePath: '/index.html',
          ttl: cdk.Duration.minutes(5),
        },
      ],
    });

    this.url = `https://${this.distribution.distributionDomainName}`;

    const clientDir = path.join(__dirname, '..', '..', 'workspace', 'client');
    const staticDeploy = new s3deploy.BucketDeployment(this, 'DeployClient', {
      sources: [
        s3deploy.Source.asset(clientDir, {
          exclude: [
            '*.md',
            'package.json',
            'package-lock.json',
            'node_modules',
            'node_modules/**',
            'config.js',
            'config.example.js',
            '**/.DS_Store',
          ],
        }),
      ],
      destinationBucket: this.bucket,
      distribution: this.distribution,
      distributionPaths: ['/*'],
    });

    if (props.samplesApiUrl && props.samplesApiKeySecret) {
      const writer = new lambda.Function(this, 'ConfigWriter', {
        functionName: 'wirejac-write-meta-config',
        runtime: lambda.Runtime.PYTHON_3_12,
        handler: 'handler.handler',
        code: lambda.Code.fromAsset(
          path.join(__dirname, '..', 'lambda', 'write-config'),
        ),
        timeout: cdk.Duration.seconds(30),
      });
      props.samplesApiKeySecret.grantRead(writer);
      this.bucket.grantPut(writer, 'config.js');
      writer.addToRolePolicy(
        new iam.PolicyStatement({
          actions: ['cloudfront:CreateInvalidation'],
          resources: [
            cdk.Stack.of(this).formatArn({
              service: 'cloudfront',
              region: '',
              account: cdk.Stack.of(this).account,
              resource: 'distribution',
              resourceName: this.distribution.distributionId,
            }),
          ],
        }),
      );

      const provider = new cr.Provider(this, 'ConfigWriterProvider', {
        onEventHandler: writer,
      });

      const writeConfig = new cdk.CustomResource(this, 'WriteConfigJs', {
        serviceToken: provider.serviceToken,
        properties: {
          Bucket: this.bucket.bucketName,
          ApiUrl: props.samplesApiUrl,
          SecretArn: props.samplesApiKeySecret.secretArn,
          DistributionId: this.distribution.distributionId,
          // Force rewrite when this construct changes.
          Version: '2',
        },
      });
      writeConfig.node.addDependency(staticDeploy);
    }

    new ssm.StringParameter(this, 'MetaAppUrlParam', {
      parameterName: '/wirejac/dev/meta-app-url',
      stringValue: this.url,
      description: 'CloudFront URL for the Wirejac Meta app (product UI)',
      tier: ssm.ParameterTier.STANDARD,
    });

    new ssm.StringParameter(this, 'MetaAppBucketParam', {
      parameterName: '/wirejac/dev/meta-app-bucket',
      stringValue: this.bucket.bucketName,
      description: 'S3 bucket holding the Wirejac Meta app',
      tier: ssm.ParameterTier.STANDARD,
    });

    new ssm.StringParameter(this, 'MetaAppDistributionParam', {
      parameterName: '/wirejac/dev/meta-app-distribution-id',
      stringValue: this.distribution.distributionId,
      description: 'CloudFront distribution for the Wirejac Meta app',
      tier: ssm.ParameterTier.STANDARD,
    });

    new cdk.CfnOutput(this, 'MetaAppUrl', {
      value: this.url,
      description: 'HTTPS URL for the Meta app (accelerometer dashboard)',
      exportName: 'WirejacMetaAppUrl',
    });

    new cdk.CfnOutput(this, 'MetaAppBucketName', {
      value: this.bucket.bucketName,
      description: 'S3 bucket holding Meta app static assets',
      exportName: 'WirejacMetaAppBucketName',
    });

    new cdk.CfnOutput(this, 'MetaAppDistributionId', {
      value: this.distribution.distributionId,
      description: 'CloudFront distribution ID for cache invalidation',
      exportName: 'WirejacMetaAppDistributionId',
    });
  }
}
