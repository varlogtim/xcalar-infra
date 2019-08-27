def get_stack_info(client, cfn_id):
    cluster_url = None
    response = client.describe_stacks(StackName=cfn_id)
    if 'Stacks' not in response or len(response['Stacks']) == 0:
        return {'error': response}
    stack_info = response['Stacks'][0]
    ret_struct = {}
    for param in stack_info['Parameters']:
        if 'ParameterValue' in param:
            if param['ParameterKey'] == 'InstanceType':
                ret_struct['type'] = param['ParameterValue']
            elif param['ParameterKey'] == 'ClusterSize':
                ret_struct['size'] = int(param['ParameterValue'])
    for tag in stack_info['Tags']:
        if 'Value' in tag and tag['Key'] == 'saas_owner':
            ret_struct['owner_tag'] = tag
    for output in stack_info['Outputs']:
        if output['OutputKey'] == 'S3Bucket':
            ret_struct['s3_url'] = output['OutputValue']
        elif output['OutputKey'] == 'URL':
            ret_struct['cluster_url'] = output['OutputValue']
    ret_struct['stack_status'] = stack_info['StackStatus']
    return ret_struct