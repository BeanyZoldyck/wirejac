#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib/core';
import { WirejacDevStack } from '../lib/wirejac-dev-stack';

// All Wirejac infrastructure is pinned to a single region so that deployments
// from different machines cannot silently create duplicate stacks elsewhere.
const WIREJAC_REGION = 'us-west-2';

const app = new cdk.App();
const stack = new WirejacDevStack(app, 'WirejacDevStack', {
  stackName: 'WirejacDevStack',
  description: 'Wirejac hackathon development infrastructure',
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: WIREJAC_REGION,
  },
});

cdk.Tags.of(stack).add('Project', 'wirejac');
cdk.Tags.of(stack).add('Environment', 'dev');
cdk.Tags.of(stack).add('ManagedBy', 'aws-cdk');
cdk.Tags.of(stack).add('Owner', 'big-sack');
