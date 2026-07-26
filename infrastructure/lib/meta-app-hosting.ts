import * as path from 'node:path';
import * as cdk from 'aws-cdk-lib/core';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import { Construct } from 'constructs';

/**
 * Static hosting for the Meta app (accelerometer product UI in workspace/client).
 *
 * The browser never talks to DynamoDB. It calls the Jac sample API
 * (GET /api/samples); that server reads DynamoDB. Cross-origin calls from
 * this CloudFront URL work with single-process `jac start`, which allows
 * all origins.
 */
export class MetaAppHosting extends Construct {
  public readonly bucket: s3.Bucket;
  public readonly distribution: cloudfront.Distribution;
  public readonly url: string;

  constructor(scope: Construct, id: string) {
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
    new s3deploy.BucketDeployment(this, 'DeployClient', {
      sources: [
        s3deploy.Source.asset(clientDir, {
          exclude: [
            '*.md',
            'package.json',
            'package-lock.json',
            'node_modules',
            'node_modules/**',
            '**/.DS_Store',
          ],
        }),
      ],
      destinationBucket: this.bucket,
      distribution: this.distribution,
      distributionPaths: ['/*'],
    });

    new ssm.StringParameter(this, 'MetaAppUrlParam', {
      parameterName: '/wirejac/dev/meta-app-url',
      stringValue: this.url,
      description: 'CloudFront URL for the Wirejac Meta app (product UI)',
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
  }
}
