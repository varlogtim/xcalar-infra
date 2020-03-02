Hydra Configuration

JSON file with the following keys:

    "watchers": <watchers section>
        - defines the "watcher" processes (if any).
    "scrapers": <scrapers section>
        - defines the "log scraper" functions (if any).
    "hydra": <hydra config>
        - assigns scrapers to watchers, and watchers to the hydra process


The "watchers" section:

    "watchers": { <watcher name>: <watcher config>,
                  <watcher name>: <watcher config>,
                  ... }

    Where <watcher name> is any string other than "MAIN" which is reserved for internal use.

    Where <watcher config> is:

        { "builtin": <class name>,
              or...
          "cmdline": <command line string>,
              or...
          "module_path": <module path>, "class_name": <class name>,
              and, optionally...
          "environment": <environment config> }

    Where <environment config> is a list containing any number of:
        {"target": <target name>, "value": <target value>}
            or...
        {"target": <target name>, "source": <source name>}

    Where <target_name> is the environment variable to set,
          <target value> is the value to give to <target name>,
          <source_name> is the name of an existing environment variable
                from which to obtain the value to give to <target name>

The "scrapers" section:

    "scrapers": { <scraper name>: <scraper config>,
                  <watcher name>: <scraper config>,
                  ... }

    Where <scraper name> is any string.

    Where <scraper config> is:
        { "builtin": <class name>,
              or...
          "module_path": <module path>, "class_name": <class name> }

The "hydra" config:

    "hydra": [<watcher assignment>, ...]

    Where <watcher assignment>:
        {"name": <watcher name as previously defined above or "MAIN">,
            optionally...
         "frequency": <frequency in seconds>,
            optionally...
         "scrapers": [<scraper name as previously defined>, ...]}
