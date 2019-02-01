# couchdb-views-update
Update CouchDB views by accessing them efficiently on regular interval. CouchDB views are only updated if accessed. For busy sites, where documents are added constantly, lookup through views is slow if the views are rarely accessed. This script remediates the situation by performing view access on regular interval so that furture lookups will be more responsive.

## Getting Started

### Prerequisites
This script requires Perl 5.24 or later along with Mojolicious framework. You also need to install JSON::XS. If SSL is required, you need to install SSLeay module as well. Details can be found at [Mojolicious Website](https://mojolicious.org)

### Deployment
After the environment is set up (assuming Perl home directory is at /opt/perl524), use [configuration file](https://github.com/ttdsuen/couchdb-views-update/blob/master/config_sample.json) as a sample and construct yours. For example,

```
export PATH=/opt/perl524/bin:$PATH
CONFIG=/opt/couchdb-views-update/config/config.json
perl /opt/couchdb-views-update/bin/couchdb-views-update.pl
```

## Author

* **Daniel Suen**


## License

This project is licensed under the Apache License 2.0 - see the [LICENSE.md](LICENSE.md) file for details

