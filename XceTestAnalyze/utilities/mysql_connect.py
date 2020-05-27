import mysql.connector
from mysql.connector import Error

def insert(log_list):
  try:
    connection = mysql.connector.connect(
      host='samvm1',
      user='root',
      passwd='root',
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
  try:
    connection = mysql.connector.connect(
      host='samvm1',
      user='root',
      passwd='root',
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