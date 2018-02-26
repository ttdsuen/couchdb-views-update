#!/usr/bin/env perl
#
# CONFIG - env variable, value is JSON encoded configurations
#
# Author: Daniel Suen
# Date: 2018-02-24
#

use strict;
use warnings;

use JSON::XS;
use Mojo::Log;
use Mojo::UserAgent;
use MIME::Base64;

my $headers = {
  'Content-Type' => 'application/json',
  'Accept' => 'application/json'
};

my $log = Mojo::Log->new;
my $json_xs = JSON::XS->new->allow_nonref->utf8;


#
# validate configurations
#
sub is_valid {
  my $spec = shift;

  return 0 if !exists $spec->{couchdbs};
  return 0 if ref($spec->{couchdbs}) ne 'ARRAY';
  return 0 if @{$spec->{couchdbs}} <= 0;
  foreach my $couchdb (@{$spec->{couchdbs}}) {
    return 0 if !exists $couchdb->{url};
    return 0 if ref($couchdb->{url}) ne '';
  }
  return 1;
}

#
# set userinfo for url
#
sub add_userinfo {
  my ($url, $ptr) = @_;

  #
  # insert username:decode_base64(password) into url
  #
  my $url_obj = Mojo::URL->new($url);
  $url_obj = $url_obj->userinfo(
    sprintf("%s:%s", $ptr->{username}, decode_base64($ptr->{password}))
  );
  return $url_obj->to_unsafe_string;
}

#
# configures URL
#
sub config_url {
  my ($couchdb, $db, $url) = @_;

  if (exists $couchdb->{dbs}->{$db}) {
    my $db_ptr = $couchdb->{dbs}->{$db};
    if (exists $db_ptr->{username} && exists $db_ptr->{password} &&
        ref($db_ptr->{username}) eq '' && ref($db_ptr->{password}) eq '') {
      #
      # username and password exists at the db level
      #
      return &add_userinfo($url, $db_ptr);
    }
  } elsif (exists $couchdb->{username} && exists $couchdb->{password} &&
           ref($couchdb->{username}) eq '' && ref($couchdb->{password}) eq '') {
    #
    # username and password exists at the instance level
    #
    return &add_userinfo($url, $couchdb);
  }
  return $url;
}

#
# configures user agent
#
sub config_ua {
  my ($couchdb, $ua) = @_;

  if (exists $couchdb->{ua}) {
    my $ua_ptr = $couchdb->{ua};
    foreach my $param ((qw/ca cert key request_timeout connect_timeout inactivity_timeout/)) {
      if (exists $ua_ptr->{$param} && ref($ua_ptr->{$param}) eq '') {
        $ua->$param($ua_ptr->{$param});
      }
    }
  }
  return $ua;
}

#
# handles 4xx/5xx or connection errors from CouchDB
#
sub handle_error {
  my ($tx, $err) = @_;

  my $req = $tx->req;

  # 
  # 4xx/5xx errors or connection error
  #
  $log->error(
    sprintf(
      "%s %s failed - %s: %s",
      $req->method, $req->url->to_string, $err->{code}, $err->{message}
    )
  ) if $err->{code};
  $log->error(
    sprintf(
      "%s %s failed - connection error: %s",
      $req->method, $req->url->to_string, $err->{message}
    )
  ) if !$err->{code};
}

#
# handles 3xx redirections from CouchDB
#
sub handle_3xx {
  my $tx = shift;

  my $req = $tx->req;

  $log->warn(
    sprintf(
      "%s %s returns 3xx - %s %s", $req->method, $req->url->to_string,
      $tx->res->{code}, $json_xs->encode($tx->res)
    )
  );
}

#
# this is to keep track of the design docs being updated,
# we won't do the update if we are operating against it.
#
my $working_design_docs = { };

#
# update a view
#
sub update_view {
  my %p = @_;

  my ($couchdb, $db, $design, $view, $ua, $ee, $cb) = (
    $p{couchdb}, $p{db}, $p{design}, $p{view}, $p{ua}, $p{ee}, $p{cb}
  );

  my $url = &config_url(
    $couchdb, $db,
    sprintf("%s/%s/%s%s?key=1&limit=1", $couchdb->{url}, $db, $design, $view)
  );
  $log->info("GET $url");
  #
  # we will lower the timeout values as we do not really need to wait for
  # the response
  #
  my ($request_timeout, $inactivity_timeout) = (
    $ua->request_timeout, $ua->inactivity_timeout
  );
  $ua->request_timeout(3); $ua->inactivity_timeout(2.5);
  $ua->get($url => $headers => sub {
    my ($ua, $tx) = @_;

    $ua->request_timeout($request_timeout);
    $ua->inactivity_timeout($inactivity_timeout);

    #
    # we may hit error here, which may be normal
    #
    if (my $err = $tx->error) {
      if ($err->{code}) {
        #
        # we hit 4xx/5xx error, which is not normal
        #
        return $cb->($ee, 0);
      }
      #
      # we hit connection error, if it is request/inactivity timeout, we are fine
      #
      if ($err->{message} =~ /timeout/i && $err->{message} =~ /(request|inactivity)/i) {
        $log->info("$db/$design done through $view");
        return $cb->($ee, 1);
      } else {
        #
        # we hit something else, let's try another view
        #
        return $cb->($ee, 0);
      }
    } else {
      #
      # we don't get error, so we are done
      #
      $log->info("$db/$design done through $view");
      return $cb->($ee, 1);
    }
  });
}

#
# update a view defined in a design document
#
sub update_design_doc {
  my ($ua, $couchdb, $db, $design, $views) = @_;

  my $couchdb_url = $couchdb->{url};
  return if exists $working_design_docs->{"$couchdb_url/$db/$design"};
  $working_design_docs->{"$couchdb_url/$db/$design"} = 1;
  if (@$views <= 0) {
    delete $working_design_docs->{"$couchdb_url/$db/$design"};
    return;
  }
  my $cb = sub {
    my ($ee, $done) = @_;

    $ee->emit('poke') if !$done;
    if ($done) {
      delete $working_design_docs->{"$couchdb_url/$db/$design"};
    }
  };

  my $ee = Mojo::EventEmitter->new;
  $ee->on(poke => sub {
    my $view = shift @$views;
    &update_view(
      couchdb => $couchdb, db => $db, ua => $ua,
      design => $design, view => "/_view/$view", ee => $ee, cb => $cb
    );
  });
  $ee->emit('poke');
}

#
# update all views of a couchdb instance
#
sub main {
  my ($ua, $couchdb) = @_;

  #
  # fetch all databases - skip ones with leading underscores
  #
  my $url = sprintf("%s/_all_dbs", $couchdb->{url});
  $log->info("GET $url");
  $ua->get($url => $headers => sub {
    my ($ua, $tx) = @_;

    if (my $err = $tx->error) {
      &handle_error($tx, $err); return;
    }
    if ($tx->result->is_success) {
      my $all_dbs = $tx->res->json;
      if (!defined $all_dbs || ref($all_dbs) ne 'ARRAY') {
        $log->error(
          sprintf("GET %s failed - response is not an array or not defined", $url)
        );
        return;
      } 
      my $dbs = [ grep { $_ !~ m/^_/ } @$all_dbs ];
      foreach my $db (@$dbs) {
        #
        # fetch all design documents for $db
        #
        my $url = &config_url(
          $couchdb, $db,
          sprintf(
            "%s/%s/_all_docs?startkey=\"_design/\"&endkey=\"_design0\"&include_docs=true",
            $couchdb->{url}, $db
          )
        ); 
        $log->info("GET $url");
        $ua->get($url => $headers => sub {
          my ($ua, $tx) = @_;
  
          if (my $err = $tx->error) {
            &handle_error($tx, $err); return;
          }
          if ($tx->result->is_success) {
            my $res;
            eval { $res = $json_xs->decode($tx->res->body) };
            if ($@) {
              #
              # JSON decode failure
              #
              $log->error(
                sprintf("GET %s failed - error JSON decoding response", $url)
              );
              return;
            }
            my $docs = [ map { $_->{doc} } @{$res->{rows}} ];
            foreach my $doc (@$docs) {
              my $design = $doc->{_id};
              my $views = [ keys %{$doc->{views}} ];
              &update_design_doc($ua, $couchdb, $db, $design, $views);
            }
          } else {
            #
            # we shouldn't get here
            #
            &handle_3xx($tx);
          }
        });
      }
    } else {
      #
      # we should't get here
      #
      &handle_3xx($tx);
    }
  });
}

my $config = $ENV{CONFIG} // "{\"couchdbs\":[]}";
$config =~ s/^\s*//g; $config =~ s/\s*$//g;
my $spec;
eval { $spec = $json_xs->decode($config) };
if ($@) {
  print STDERR "failed JSON decoding config, script aborted!\n";
  exit(1);
} elsif (!&is_valid($spec)) {
  print STDERR "invalid config, script aborted!\n";
  exit(1);
}

if (@{$spec->{couchdbs}}) {
  foreach my $couchdb (@{$spec->{couchdbs}}) {
    my $ua = Mojo::UserAgent->new;
    &config_ua($couchdb, $ua);
    Mojo::IOLoop->recurring($couchdb->{every} => sub { &main($ua, $couchdb) });
    &main($ua, $couchdb);
  }
  Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
}

