import subprocess
import shlex
import mysql.connector
from mysql.connector import Error


def dig_portnumber(server_name):
  cmd = f'dig SRV {server_name} +short'
  proc = subprocess.Popen(shlex.split(cmd), stdout=subprocess.PIPE)
  out, err = proc.communicate()
  port = out.decode("utf-8").split()[2]
  return port

def insert(log_list):
  host = 'mysql.service.consul'
  port = dig_portnumber(host)
  try:
    connection = mysql.connector.connect(
      host= host,
      user='root',
      passwd='xcalar',
      port= port,
      database='xce_test_db'
    )

    mycursor = connection.cursor()
    query = '''INSERT IGNORE INTO xce_test_logs (test_timestamp, build_number, subset, delta, slave_host, status) VALUES (%s, %s, %s, %s, %s, %s)'''
    mycursor.executemany(query, log_list)
    connection.commit()
    print(mycursor.rowcount, "record inserted.")

  except Error as e:
    print("Error while connecting to MySQL", e)

  finally:
    if (connection.is_connected()):
      mycursor.close()
      connection.close()
      print("MySQL connection is closed")


def insert_info(lnfo_dict):
  host = 'mysql.service.consul'
  port = dig_portnumber(host)
  try:
    connection = mysql.connector.connect(
      host=host,
      user='root',
      passwd='xcalar',
      port=port,
      database='xce_test_db'
    )

    mycursor = connection.cursor()
    query = '''INSERT IGNORE INTO xce_test_info (id, test_timestamp, job_name, displayName, building, description, duration, estimatedDuration, executor, fullDisplayName, queueId, url, builtOn, result)
                                        VALUES (%(id)s, %(test_timestamp)s, %(job_name)s, %(displayName)s, %(building)s, %(description)s, %(duration)s, %(estimatedDuration)s, %(executor)s, %(fullDisplayName)s, %(queueId)s, %(url)s, %(builtOn)s, %(result)s)'''

    mycursor.execute(query, lnfo_dict)
    connection.commit()
    print(mycursor.rowcount, "record inserted.")

  except Error as e:
    print("Error while connecting to MySQL", e)

  finally:
    if (connection.is_connected()):
      mycursor.close()
      connection.close()
      print("MySQL connection is closed")
