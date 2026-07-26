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
