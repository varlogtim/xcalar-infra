from selenium import webdriver
import BaseHTTPServer
import threading
import urllib2
from pyvirtualdisplay import Display
import socket
from argparse import ArgumentParser

"""
Please read README.md for env setup
"""

CHROME_DRIVER_PATH = "/usr/bin/chromedriver"
TEST_RESULT = None
QUIT_SIGNAL = threading.Event()
DEFAULT_SERVER_PORT = 5909

"""
Handler is http request routing implementation.
It supports opening/closing the web browser and notifying Jenkins.
"""
class Handler( BaseHTTPServer.BaseHTTPRequestHandler ):

    driver = None
    ROUTE_START = '/start'
    ROUTE_STATUS = '/status'
    ROUTE_CLOSE = '/close'
    ROUTE_ACTION = "name"

    """
    TODO: restructure the http request
    Http request/response should be consistent with
    Xcalar Design
    """
    def do_GET(self):
        global TEST_RESULT
        print self.path
        params = self.parse(self.path)
        print params
        action = None
        if self.ROUTE_ACTION in params:
            action = params[self.ROUTE_ACTION]
        
        if action=="start":
            """
            Sample url: http://localhost:5909/action?name=start&mode=ten&host=10.10.4.134&server=euler&port=5909&users=1
            """
            self.processStart(params)
        elif action=="close":
            """
            Sample url: http://localhost:5909/action?name=close
            """
            self.processClose(params)
        elif action=="getstatus":
            """
            Sample url: http://localhost:5909/action?name=getstatus
            """
            self.processGetStatus(params)
        # TODO: once test suite update the callback url, this
        # route needs to change as well
        elif self.path.startswith(self.ROUTE_STATUS):
            """
            Sample url: http://localhost:5909/status/user0%3Fstatus%3Aclose%26
            """
            self.path = self.path.strip("/")
            if len(self.path.split("/")) < 2:
                if TEST_RESULT:
                    self.mark_SUCCESS("Finished: "+TEST_RESULT)
                else:
                    self.mark_SUCCESS("Still running")
                return
            status = self.path.split("/")[1]
            self.mark_SUCCESS()
            TEST_RESULT = urllib2.unquote(status)

    def processStart(self, params):
        users = params.get("users", "1")
        mode = params.get("mode", "ten")
        server = params.get("server", socket.gethostname())
        port = params.get("port", str(DEFAULT_SERVER_PORT))
        host = params.get("host", socket.gethostname())
        testSuiteUrl = "http://"+host+"/test.html?auto=y&mode="+mode+"&host="+host+"&server="+socket.gethostname()+"%3A"+port+"&users="+users
        self.driver = webdriver.Chrome(CHROME_DRIVER_PATH)
        self.driver.get(testSuiteUrl)
        self.mark_SUCCESS("Started")


    def processClose(self, params):
        if not TEST_RESULT:
            self.mark_SUCCESS("Still running")
        else:
            self.mark_SUCCESS("Finished: "+TEST_RESULT)
            QUIT_SIGNAL.set()

    def processGetStatus(self, params):
        if TEST_RESULT:
            self.mark_SUCCESS("Finished: "+TEST_RESULT)
        else:
            self.mark_SUCCESS("Still running")
        return


    """
    This will send back a 200 http response
    """
    def mark_SUCCESS(self, msg=""):
        self.send_response(200)
        self.send_header( 'Content-type', 'text/html' )
        self.end_headers()
        self.wfile.write(msg)

    """
    Parse the http request into a Map
    """
    def parse(self, request):
        paramMap = {}
        if request.startswith("/action?"):
            request = request[len("/action?"):]
            params = request.split("&")
            for param in params:
                key = param.split("=")[0]
                val = param.split("=")[1]
                paramMap[key] = val
        return paramMap

"""
Webserver is a wrapper class over BaseHTTPServer.
It serves as the middle layer between Jenkins and test manager.
It runs the actual handler in a separate thread which controlled by QUIT_SIGNAL.
"""
class Webserver:
    serverThread = None
    def __init__ (self, host='', port=DEFAULT_SERVER_PORT):
        self.server = BaseHTTPServer.HTTPServer( (host, port), Handler )

    def start(self):
        self.serverThread = threading.Thread(target=self.server.serve_forever)
        self.serverThread.start()

    def wait(self):
        QUIT_SIGNAL.wait()

    def shutdown(self):
        self.server.shutdown()

def main():
    parser = ArgumentParser()
    parser.add_argument("-t", "--target", dest="target", type=str,
                        metavar="<testCase>", default=None,
                        help="Target test suite manager host")
    parser.add_argument("-v", "--visible", dest="visible",
                        action="store_true", help="Run test in real browser")
    args = parser.parse_args()
    target = args.target
    if not target:
        print "Please give the target server that runs test suites: -t"
        return
    visible = args.visible

    if not visible:
        display = Display(visible=0, size=(800, 800))
        display.start()
    server = Webserver()
    server.start()
    server.wait()
    server.shutdown()
    if not visible:
        display.stop()
    

if __name__ == "__main__":
    main()
