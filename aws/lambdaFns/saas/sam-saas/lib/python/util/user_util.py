import time
def init_user(client, user_name, credit, user_table, billing_table):
    user_data = {
        'user_name': {'S':user_name}
    }
    credit_data = {
        'user_name': {
            'S':user_name
        },
        'timestamp': {
            'N': str(round(time.time() * 1000))
        },
        'credit_change': {
            'N': credit
        }
    }
    #TODO edge cases
    #insert user table sucessfully
    #but fail to insert into credit table
    response = client.put_item(
        TableName = user_table,
        Item = user_data
    )
    response = client.put_item(
        TableName = billing_table,
        Item = credit_data
    )
    return response

def get_user_info(client, user_name, user_table):
    # To-do handle edge case where user is not found
    return client.get_item(
        TableName=user_table,
        Key={
            'user_name': {
                'S': user_name
            }
        }
    )

def update_user_info(client, user_info, updates, user_table):
    update_expr = 'set'
    expr_values = {}
    for name in updates:
        value = updates[name]
        var_name = ':' + name.split('_')[0]
        update_expr += ' ' + name + ' = ' + var_name + ','
        expr_values[var_name] = value

    response = client.update_item(
        TableName=user_table,
        Key={
            'user_name': {
                'S': user_info['user_name']['S']
            }
        },
        UpdateExpression=update_expr[:-1],
        ExpressionAttributeValues=expr_values
    )
    return response
