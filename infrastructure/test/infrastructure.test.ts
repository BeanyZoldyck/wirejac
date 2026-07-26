import * as cdk from 'aws-cdk-lib/core';
import { Template, Match } from 'aws-cdk-lib/assertions';
import { WirejacDevStack } from '../lib/wirejac-dev-stack';

function synth() {
  const app = new cdk.App();
  const stack = new WirejacDevStack(app, 'TestWirejacDevStack');
  return Template.fromStack(stack);
}

test('development stack contains its deployment marker', () => {
  const template = synth();

  template.hasResourceProperties('AWS::SSM::Parameter', {
    Name: '/wirejac/dev/stack-status',
    Type: 'String',
    Value: 'ready',
  });
});

test('samples table is provisioned for the server API', () => {
  const template = synth();

  template.hasResourceProperties('AWS::DynamoDB::Table', {
    TableName: 'wirejac-samples',
    BillingMode: 'PAY_PER_REQUEST',
    KeySchema: [
      { AttributeName: 'session_id', KeyType: 'HASH' },
      { AttributeName: 'sample_id', KeyType: 'RANGE' },
    ],
    AttributeDefinitions: Match.arrayWith([
      { AttributeName: 'session_id', AttributeType: 'S' },
      { AttributeName: 'sample_id', AttributeType: 'S' },
    ]),
  });

  template.hasResourceProperties('AWS::SSM::Parameter', {
    Name: '/wirejac/dev/samples-table-name',
    Type: 'String',
    Value: 'wirejac-samples',
  });
});

test('meta app is hosted on private S3 behind CloudFront', () => {
  const template = synth();

  template.resourceCountIs('AWS::CloudFront::Distribution', 1);
  template.resourceCountIs('AWS::CloudFront::OriginAccessControl', 1);

  template.hasResourceProperties('AWS::SSM::Parameter', {
    Name: '/wirejac/dev/meta-app-url',
    Type: 'String',
  });

  template.hasResourceProperties('AWS::S3::Bucket', {
    PublicAccessBlockConfiguration: {
      BlockPublicAcls: true,
      BlockPublicPolicy: true,
      IgnorePublicAcls: true,
      RestrictPublicBuckets: true,
    },
  });
});
