import pandas as pd
import subprocess
import shlex
import mysql.connector
from mysql.connector import Error
from utilities.chart import bar_char, horizontal_bar_chart, barh

def dig_portnumber(server_name):
  cmd = f'dig SRV {server_name} +short'
  proc = subprocess.Popen(shlex.split(cmd), stdout=subprocess.PIPE)
  out, err = proc.communicate()
  port = out.decode("utf-8").split()[2]
  return port

def get_connection():
  # mysql -h mysql.service.consul -P 24531 -u root
  host = 'mysql.service.consul'
  port = dig_portnumber(host)
  connection = mysql.connector.connect(
    host=host,
    port= port,
    user='root',
    passwd='xcalar',
    database='xce_test_db'
  )
  return connection


def insert(log_list):
  try:
    connection = get_connection()

    mycursor = connection.cursor()
    query = '''
              INSERT IGNORE INTO xce_test_logs (test_timestamp, build_number, subset, delta, slave_host, status) 
              VALUES (%s, %s, %s, %s, %s, %s)
            '''
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
    connection = get_connection()

    mycursor = connection.cursor()
    query = '''
              INSERT IGNORE INTO xce_test_info (id, test_timestamp, job_name, displayName, building, description, duration, estimatedDuration, executor, fullDisplayName, queueId, url, builtOn, result) 
              VALUES (%(id)s, %(test_timestamp)s, %(job_name)s, %(displayName)s, %(building)s, %(description)s, %(duration)s, %(estimatedDuration)s, %(executor)s, %(fullDisplayName)s, %(queueId)s, %(url)s, %(builtOn)s, %(result)s)
            '''

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


def iter_row(cursor, size=10):
  while True:
    rows = cursor.fetchmany(size)
    if not rows:
      break
    for row in rows:
      yield row


def query_with_fetchall(sql=None, size=10):

  try:
    connection = get_connection()
    mycursor = connection.cursor()

    ## SQL
    mycursor.execute(sql)
    task_list= []
    volumn_list=[]
    for row in iter_row(mycursor, size):
      volumn_list.append(row[0])
      task_list.append(row[1])
      print(row)

    return task_list, volumn_list

  except Error as e:
    print("Error while connecting to MySQL", e)

  finally:
    if (connection.is_connected()):
      mycursor.close()
      connection.close()
      # print("MySQL connection is closed")


##
## insight
##
def find_fail_the_most_frequently(size= 10, days=182):
  title = f'Fail the most frequently in last {days} days'
  print(f'\n## {title}')
  sql = f'''
      SELECT
          count(*) as c, 
          SUBSTRING_INDEX(SUBSTRING_INDEX(subset, ' ', 1), ' ', -1) AS task
      FROM xce_test_logs 
      WHERE status = 'FAIL' and DATEDIFF(NOW(), test_timestamp) <= {days}
      GROUP BY task order by c  desc limit {size}
  '''
  task_list, volumn_list = query_with_fetchall( sql , size)
  horizontal_bar_chart(tasks=task_list, nums=volumn_list, title=title, xlabel='(times)')


def find_take_the_most_avg_time(size=10, days=182):
  title = f'Take the most average time in last {days} days'
  print(f'\n## {title}')
  sql = f'''
      SELECT
          avg( abs(delta)) as avg,
          SUBSTRING_INDEX(SUBSTRING_INDEX(subset, ' ', 1), ' ', -1) AS task
      FROM xce_test_logs 
      WHERE status = 'PASS'  and  DATEDIFF(NOW(), test_timestamp) <= {days} 
      GROUP BY task order by avg desc limit {size}
  '''
  task_list, volumn_list = query_with_fetchall( sql , size)
  horizontal_bar_chart(tasks=task_list, nums=volumn_list, title= title, xlabel='(seconds)')


def find_take_the_most_time(size=10, days=182):
  title = f'Take the most time in last {days} days'
  print(f'\n## {title}')
  sql = f'''
      SELECT
          abs(delta) as delta,
          SUBSTRING_INDEX(SUBSTRING_INDEX(subset, ' ', 1), ' ', -1) AS task
      FROM xce_test_logs
      WHERE status = 'PASS' and  DATEDIFF(NOW(), test_timestamp) <= {days}
      GROUP BY task order by delta desc limit {size}
  '''
  task_list, volumn_list = query_with_fetchall( sql , size)
  horizontal_bar_chart(tasks=task_list, nums=volumn_list, title= title, xlabel='(seconds)')


def find_the_largest_stdev(size=10, days=182):
  title = f'Find the largest of standard deviation in last {days} days'
  print(f'\n## {title}')
  sql = f'''
      SELECT
          STDDEV(abs(delta)) as stdev,
          SUBSTRING_INDEX(SUBSTRING_INDEX(subset, ' ', 1), ' ', -1) AS task
      FROM xce_test_logs 
      WHERE status = 'PASS' and  DATEDIFF(NOW(), test_timestamp) <= {days}
      GROUP BY task order by stdev desc limit {size}
  '''
  task_list, volumn_list = query_with_fetchall( sql , size)
  horizontal_bar_chart(tasks=task_list, nums=volumn_list, title= title, xlabel='')