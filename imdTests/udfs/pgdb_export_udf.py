import psycopg2
import json


def __config_params():
    params = {}
    params["dbname"] = 'ecommercedb'
    params["user"] = 'jenkins'
    params["host"] = 'mssqlserver-demos-linux'
    params["password"] = 'jenkins'
    return params

customers_sql = """INSERT INTO public.customers VALUES(
            %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
            %s, %s, %s, %s, %s)
            ON CONFLICT (customerid)
            DO NOTHING;"""

customer_phone_sql = """INSERT INTO public.customer_phone VALUES(
            %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
            %s, %s, %s)
            ON CONFLICT (phonenum)
            DO NOTHING;"""

address_sql = """INSERT INTO public.address VALUES(
            %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
            %s, %s)
            ON CONFLICT (addressid)
            DO NOTHING;"""

customer_address_sql = """INSERT INTO public.customer_address VALUES(
            %s, %s, %s, %s)
            ON CONFLICT (addressid, customerid)
            DO NOTHING;"""

orders_sql = """INSERT INTO public.orders VALUES(
            %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
            %s, %s, %s, %s)
            ON CONFLICT (orderid)
            DO NOTHING;"""

order_items_sql = """INSERT INTO public.order_items VALUES(
            %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s,
            %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (orderitemsid, orderid)
            DO NOTHING;"""


def main(inStr):
    inObj = json.loads(inStr)
    rows = inObj["fileContents"]
    filePath = inObj["filePath"]
    chunks = filePath.lstrip("/").split("/")
    tableName = chunks[-2]
    sqlStatement = globals()["{}_sql".format(tableName)]
    try:
        params = __config_params()
        conn = psycopg2.connect(**params)
        cur = conn.cursor()
        headers = []
        listVals = []
        for row in rows.split('\n'):
            if not headers:
                for col in row.split('\t'):
                    headers.append(col)
                continue
            if not row.strip():
                continue
            vals = []
            for idx, col in enumerate(row.split('\t')):
                col = col.replace('\'', '')
                vals.append('{}'.format(col))
            if vals:
                listVals.append(tuple(vals))
        cur.executemany(sqlStatement, listVals)
        conn.commit()
        cur.close()
    except (Exception, psycopg2.DatabaseError) as error:
        with open("/tmp/testDbExport.txt", 'w+') as f:
            f.write(tableName + '\n')
            f.write(str(listVals) + "\n")
            f.write(str(error) + "\n")
            f.write(sqlStatement + "\n")
            raise error
    finally:
        if conn is not None:
            conn.commit()
            conn.close()