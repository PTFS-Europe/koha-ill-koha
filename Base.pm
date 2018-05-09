package Koha::Illbackends::Koha::Base;

# Copyright 2017 Alex Sassmannshausen <alex.sassmannshausen@gmail.com>
# Copyright 2018 Martin Renvoize <martin.renvoize@ptfs-europe.com>
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;
use DateTime;
use Koha::Illrequestattribute;
use Koha::Patrons;
use LWP::UserAgent;
use URI;
use URI::Escape;
use Catmandu::Importer::SRU;
use Try::Tiny;

# Modules imminently being deprecated
use C4::Biblio qw( AddBiblio );
use C4::Breeding qw( Z3950Search );
use C4::ImportBatch qw( GetImportRecordMarc );

=head1 NAME

Koha::Illrequest::Backend::Koha - Koha to Koha ILL Backend

=head1 SYNOPSIS

Koha ILL implementation for the SRU + ILS-DI backend

=head1 DESCRIPTION

=head2 Overview

We will be providing the Abstract interface which requires we implement the
following methods:
- create        -> initial placement of the request for an ILL order
- confirm       -> confirm placement of the ILL order
- renew         -> request a currently borrowed ILL be renewed in the backend
- cancel        -> request an already 'confirm'ed ILL order be cancelled
- status        -> request the current status of a confirmed ILL order
- status_graph  -> return a hashref of additional statuses

Each of the above methods will receive the following parameter from
Illrequest.pm:

  {
    request => $request,
    other   => $other,
  }

where:

- $REQUEST is the Illrequest object in Koha.  It's associated
  Illrequestattributes can be accessed through the `illrequestattributes`
  method.
- $OTHER is any further data, generally provided through templates .INCs

Each of the above methods should return a hashref of the following format:

  return {
    error   => 0,
    # ^------- 0|1 to indicate an error
    status  => 'result_code',
    # ^------- Summary of the result of the operation
    message => 'Human readable message.',
    # ^------- Message, possibly to be displayed
    #          Normally messages are derived from status in INCLUDE.
    #          But can be used to pass API messages to the INCLUDE.
    method  => 'status',
    # ^------- Name of the current method invoked.
    #          Used to load the appropriate INCLUDE.
    stage   => 'commit',
    # ^------- The current stage of this method
    #          Used by INCLUDE to determine HTML to generate.
    #          'commit' will result in final processing by Illrequest.pm.
    next    => 'illview'|'illlist',
    # ^------- When stage is 'commit', should we move on to ILLVIEW the
    #          current request or ILLLIST all requests.
    value   => {},
    # ^------- A hashref containing an arbitrary return value that this
    #          backend wants to supply to its INCLUDE.
  };

=head2 On the Koha backend

The Koha backend uses Koha's SRU server to perform searches against other
instances, and it's ILS-DI API to 'confirm' ill requests.

The backend has the notion of targets, each of which is a Koha instance
definition consisting of
  {
    $name => {
      SRU => 'sru_base_uri',
      ILSDI => 'ilsdi_base_uri',
      user => 'remote_user_name',
      password => 'remote_password',
    },
  }

=head1 API

=head2 Class Methods

=cut

=head3 new

  my $backend = Koha::Illrequest::Backend::Koha->new;

=cut

sub new {

  # -> instantiate the backend
  my ($class, $params) = @_;

  my $self = {

    # FIXME: This should be loaded from a configuration.  We should allow
    # multiple targets.
    targets => {
      'KOHA DEMO' => {
        ZID      => 6,
        ILSDI    => 'https://demo.koha-ptfs.eu/cgi-bin/koha/ilsdi.pl',
        user     => 'alex_library',
        password => 'zoom1JaeC1EiJie',
      },
    },
    framework => 'ILL',
  };
  bless($self, $class);
  return $self;
}

sub name {
  return "Koha";
}

=head3 metadata

Return a hashref containing canonical values from the key/value
illrequestattributes store.

=cut

sub metadata {
  my ($self, $request) = @_;
  my $attrs = $request->illrequestattributes;
  return {
    ID     => $attrs->find({type => 'bib_id'})->value,
    Title  => $attrs->find({type => 'title'})->value,
    Author => $attrs->find({type => 'author'})->value,
    Target => $attrs->find({type => 'target'})->value,
  };
}

=head3 capabilities

$capability = $backend->capabilities($name);

Return the sub implementing a capability selected by NAME, or 0 if that
capability is not implemented.

=cut

sub capabilities {
  my ($self, $name) = @_;
  my $capabilities = {

    # We don't implement unmediated for now
    # unmediated_ill => sub { $self->confirm(@_); }
  };
  return $capabilities->{$name};
}

=head3 status_graph

=cut

sub status_graph {
  return {
    MIG => {
      prev_actions   => ['NEW', 'REQREV', 'QUEUED',],
      id             => 'MIG',
      name           => 'Backend Migration',
      ui_method_name => 'Switch provider',
      method         => 'migrate',
      next_actions   => [],
      ui_method_icon => 'fa-search',
    },
  };
}

=head3 create

  my $response = $backend->create({
  request    => $requestdetails,
  other      => $other,
  });

This is the initial creation of the request.  We search our Koha targets using
Catmandu's SRU library, and provide a choice from the results from all
targets.

We provide no paging and only rudimentary branch & borrower validation.

=cut

sub create {

  # -> initial placement of the request for an ILL order
  my ($self, $params) = @_;
  my $other = $params->{other};

  my $stage = $other->{stage};
  if (!$stage || $stage eq 'init') {

    # We simply need our template .INC to produce a search form.
    return {
      error   => 0,
      status  => '',
      message => '',
      method  => 'create',
      stage   => 'search_form',
      value   => $params,
    };
  }
  elsif ($stage eq 'search_form') {

    # Received search query in 'other'; perform search...
    my ($brw_count, $brw) = _validate_borrower($other->{'cardnumber'}, $stage);
    my $result = {
      status  => "",
      message => "",
      error   => 1,
      value   => {},
      method  => "create",
      stage   => "init",
    };
    if (_fail($other->{'branchcode'})) {
      $result->{status} = "missing_branch";
      $result->{value}  = $params;
      return $result;
    }
    elsif (!Koha::Libraries->find($other->{'branchcode'})) {
      $result->{status} = "invalid_branch";
      $result->{value}  = $params;
      return $result;
    }
    elsif ($brw_count == 0) {
      $result->{status} = "invalid_borrower";
      $result->{value}  = $params;
      return $result;
    }
    elsif ($brw_count > 1) {

      # We must select a specific borrower out of our options.
      $params->{brw}   = $brw;
      $result->{value} = $params;
      $result->{stage} = "borrowers";
      $result->{error} = 0;
      return $result;
    }
    else {
      # Perform the search
      my $search = {
        biblionumber => 0,    # required by C4::Breeding::Z3950Search
        page => $other->{page} ? $other->{page} : 1,
        id => [map { $self->{targets}->{$_}->{ZID} } keys %{$self->{targets}}],
        isbn          => $other->{isbn},
        issn          => $other->{issn},
        title         => $other->{title},
        author        => $other->{author},
        dewey         => $other->{dewey},
        subject       => $other->{subject},
        lccall        => $other->{lccall},
        controlnumber => $other->{controlnumber},
        stdid         => $other->{stdid},
        srchany       => $other->{srchany},
      };
      my $results = $self->_search($search);

      # Construct the response
      my $response = {
        status         => 200,
        message        => "",
        error          => 0,
        value          => $results,
        method         => 'create',
        stage          => 'search_results',
        borrowernumber => $brw->borrowernumber,
        cardnumber     => $other->{cardnumber},
        branchcode     => $other->{branchcode},
        backend        => $other->{backend},
        query          => $search,
        params         => $params
      };
      return $response;
    }

  }
  elsif ($stage eq 'search_results') {
    my $other = $params->{other};

    my ($biblionumber, $remote_id)
      = $self->_add_from_breeding($other->{breedingid}, $self->{framework});

    my $request_details = {
      target => $other->{target},
      bib_id => $remote_id,
      title  => $other->{title},
      author => $other->{author},
    };

    # ...Populate Illrequest
    my $request = $params->{request};
    $request->borrowernumber($other->{borrowernumber});
    $request->branchcode($other->{branchcode});
    $request->status('NEW');
    $request->backend($other->{backend});
    $request->placed(DateTime->now);
    $request->updated(DateTime->now);
    $request->biblio_id($biblionumber);
    $request->store;

    # ...Populate Illrequestattributes
    while (my ($type, $value) = each %{$request_details}) {
      Koha::Illrequestattribute->new({
        illrequest_id => $request->illrequest_id,
        type          => $type,
        value         => $value,
      })->store;
    }

    # -> create response.
    return {
      error   => 0,
      status  => '',
      message => '',
      method  => 'create',
      stage   => 'commit',
      next    => 'illview',
      value   => $request_details,
    };
  }
  else {
    # Invalid stage, return error.
    return {
      error   => 1,
      status  => 'unknown_stage',
      message => '',
      method  => 'create',
      stage   => $params->{stage},
      value   => {},
    };
  }
}

=head3 migrate

Migrate a request into or out of this backend.

=cut

sub migrate {
  my ($self, $params) = @_;
  my $other = $params->{other};

  my $stage = $other->{stage};
  my $step  = $other->{step};

  # Recieve a new request from another backend and suppliment it with
  # anything we require speficifcally for this backend.
  if (!$stage || $stage eq 'immigrate') {

    # Fetch original request details
    my $original_request = Koha::Illrequests->find($other->{illrequest_id});

    # Initiate immigration search
    if (!$step || $step eq 'init') {

      # Initiate search with details from last request
      my $search = {
        biblionumber => 0,    # required by C4::Breeding::Z3950Search
        page => $other->{page} ? $other->{page} : 1,
        id => [map { $self->{targets}->{$_}->{ZID} } keys %{$self->{targets}}],
      };
      my @recognised_attributes
        = (
        qw/isbn issn title author dewey subject lccall controlnumber stdid srchany/
        );
      my $original_attributes = $original_request->illrequestattributes->search(
        {type => {'-in' => \@recognised_attributes}});
      my $search_attributes
        = {map { $_->type => $_->value } ($original_attributes->as_list)};
      $search = {%{$search}, %{$search_attributes}};

      # Perform a search
      my $results = $self->_search($search);

      # Construct the response
      my $response = {
        status        => 200,
        message       => "",
        error         => 0,
        value         => $results,
        method        => 'migrate',
        stage         => 'immigrate',
        step          => 'search_results',
        illrequest_id => $other->{illrequest_id},
        backend       => $self->name,
        query         => $search,
        params        => $params
      };
      return $response;
    }

    # Import from search results
    elsif ($step eq 'search_results') {
      my ($biblionumber, $remote_id)
        = $self->_add_from_breeding($other->{breedingid}, $self->{framework});

      my $new_request = $params->{request};
      $new_request->borrowernumber($original_request->borrowernumber);
      $new_request->branchcode($original_request->branchcode);
      $new_request->status('NEW');
      $new_request->backend($self->name);
      $new_request->placed(DateTime->now);
      $new_request->updated(DateTime->now);
      $new_request->biblio_id($biblionumber);
      $new_request->store;

      my $request_details = {
        target => $other->{target},
        bib_id => $remote_id,
        title  => $other->{title},
        author => $other->{author},
      };
      $request_details->{migrated_from} = $original_request->illrequest_id;

      while (my ($type, $value) = each %{$request_details}) {
        Koha::Illrequestattribute->new({
          illrequest_id => $new_request->illrequest_id,
          type          => $type,
          value         => $value,
        })->store;
      }

      return {
        error   => 0,
        status  => '',
        message => '',
        method  => 'migrate',
        stage   => 'commit',
        next    => 'emigrate',
        value   => $params,
      };
    }
  }

  # Cleanup any outstanding work and close the request.
  elsif ($stage eq 'emigrate') {
    my $request = $params->{request};

    # Just cancel the original request now it's been migrated away
    $request->status("REQREV");
    $request->orderid(undef);
    $request->store;

    # Clean up the temporary bib record for the migrated request
    #if ( my $biblio = $request->biblio ) {
    #    DeleteBiblio( $biblio->biblionumber );
    #}

    return {
      error   => 0,
      status  => '',
      message => '',
      method  => 'migrate',
      stage   => 'commit',
      value   => $params,
    };
  }
}

=head3 confirm

  my $response = $backend->confirm({
    request => $requestdetails,
    other   => $other,
  });

Confirm the placement of the previously "selected" request (by using the
'create' method).

In this case we will generally use $request.
This will be supplied at all times through Illrequest.  $other may be supplied
using templates.

=cut

sub confirm {

  # -> confirm placement of the ILL order
  my ($self, $params) = @_;

  # Turn Illrequestattributes into a plain hashref
  my $value      = {};
  my $attributes = $params->{request}->illrequestattributes;
  foreach my $attr (@{$attributes->as_list}) {
    $value->{$attr->type} = $attr->value;
  }
  my $target = $self->{targets}->{$value->{target}};

  # Submit request to backend...

  # Authentication:
  my $url       = URI->new($target->{ILSDI});
  my $key_pairs = {
    'service'  => 'AuthenticatePatron',
    'username' => $target->{user},
    'password' => $target->{password},
  };
  $url->query_form($key_pairs);
  my $rsp = $self->_request({method => 'GET', url => $url});

  # Catch LWP Errors
  if ($self->{error}) {
    return {
      error   => 1,
      status  => '',
      message => "ILDI Service Error: Request - $url, "
        . "Status - $self->{error}->{status}, "
        . "Content - $self->{error}->{content}, $url",
      method => 'confirm',
      stage  => 'confirm',
      next   => '',
      value  => $value
    };
  }

  my $doc = XML::LibXML->load_xml(string => $rsp);

  # Catch AuthenticatePatron Errors
  my $code_query = "//AuthenticatePatron/code/text()";
  my $code
    = $doc->findnodes($code_query)
    ? ${$doc->findnodes($code_query)}[0]->data
    : undef;
  return {
    error   => 1,
    status  => '',
    message => "Service Authentication Error: $code",
    method  => 'confirm',
    stage   => 'confirm',
    next    => '',
    value   => $value
    }
    if defined($code);

  # Stash the authenticated service user id
  my $id_query = "//AuthenticatePatron/id/text()";
  my $id       = ${$doc->findnodes($id_query)}[0]->data;

  # Place the request
  $url       = URI->new($target->{ILSDI});
  $key_pairs = {
    'service'          => 'HoldTitle',
    'patron_id'        => $id,
    'bib_id'           => $value->{bib_id},
    'request_location' => '127.0.0.1',
  };
  $url->query_form($key_pairs);
  $rsp = $self->_request({method => 'GET', url => $url});

  # Catch LWP Errors
  if ($self->{error}) {
    return {
      error   => 1,
      status  => '',
      message => "ILDI Service Error: Request - $url, "
        . "Status - $self->{error}->{status}, "
        . "Content - $self->{error}->{content}, $url",
      method => 'confirm',
      stage  => 'confirm',
      next   => '',
      value  => $value
    };
  }

  $doc = XML::LibXML->load_xml(string => $rsp);

  # Catch HoldTitle Errors
  $code_query = "//HoldTitle/code/text()";
  $code
    = $doc->findnodes($code_query)
    ? ${$doc->findnodes($code_query)}[0]->data
    : undef;
  return {
    error   => 1,
    status  => '',
    message => "Service Request Error: $code",
    method  => 'confirm',
    stage   => 'confirm',
    next    => '',
    value   => $value
    }
    if defined($code);

  # Stash the hold request response
  my $pickup_query = "//HoldTitle/pickup_location/text()";
  die("Placing hold failed:", $rsp) if !${$doc->findnodes($pickup_query)}[0];

  my $request = $params->{request};
  $request->cost("0 GBP");
  $request->orderid($value->{bib_id});
  $request->status("REQ");
  $request->store;

  # ...then return our result:
  return {
    error   => 0,
    status  => '',
    message => '',
    method  => 'confirm',
    stage   => 'commit',
    next    => 'illview',
    value   => $value,
  };
}

=head3 renew

  my $response = $backend->renew({
  request    => $requestdetails,
  other      => $other,
  });

Attempt to renew a request that was supplied through backend and is currently
in use by us.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub renew {

  # -> request a currently borrowed ILL be renewed in the backend
  my ($self, $params) = @_;
  return {
    error   => 1,
    status  => 404,
    message => "Not Implemented",
    method  => 'renew',
    stage   => 'fake',
    value   => {},
  };
}

=head3 cancel

  my $response = $backend->cancel({
    request => $requestdetails,
    other   => $other,
  });

We will attempt to cancel a request that was confirmed.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub cancel {

  # -> request an already 'confirm'ed ILL order be cancelled
  my ($self, $params) = @_;
  return {
    error   => 1,
    status  => 404,
    message => "Not Implemented",
    method  => 'cancel',
    stage   => 'fake',
    value   => {},
  };
}

=head3 status

  my $response = $backend->create({
    request => $requestdetails,
    other   => $other,
  });

We will try to retrieve the status of a specific request.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub status {

  # -> request the current status of a confirmed ILL order
  my ($self, $params) = @_;
  return {
    error   => 1,
    status  => 404,
    message => "Not Implemented",
    method  => 'status',
    stage   => 'fake',
    value   => {},
  };
}

#### Helpers

=head3 _search

  my $response = $self->_search($query);

Given a search query hashref, perform a Z3950 search against the specified
targets and return the results (and add the results to the reserviour).

=cut

sub _search {
  my ($self, $search) = @_;

  # Mock C4::Template object used for passing parameters
  # (Z3950Search compatabilty shim)
  my $mock = MockTemplate->new;
  Z3950Search($search, $mock);

  my $response = {
    numberpending   => $mock->param('numberpending'),
    current_page    => $mock->param('current_page'),
    total_pages     => $mock->param('total_pages'),
    show_nextbutton => $mock->param('show_nextbutton'),
    show_prevbutton => $mock->param('show_prevbutton'),
    results         => $mock->param('breeding_loop'),
    servers         => $mock->param('servers'),
    errors          => $mock->param('errconn')
  };

  # Return search results
  return $response;
}

=head3 _fail

=cut

sub _fail {
  my @values = @_;
  foreach my $val (@values) {
    return 1 if (!$val or $val eq '');
  }
  return 0;
}

=head3 _request

  my $rsp = $self->_request($params);

Given a set of query details, perform an http request and return the response
or set an error flag.

=cut

sub _request {
  my ($self, $param) = @_;
  my $method     = $param->{method};
  my $url        = $param->{url};
  my $content    = $param->{content};
  my $additional = $param->{additional};

  my $req = HTTP::Request->new($method => $url);

  # add content if specified
  if ($content) {
    $req->content($content);
    $req->header('Content-Type' => 'text/xml');
  }

  my $ua  = LWP::UserAgent->new;
  my $res = $ua->request($req);
  if ($res->is_success) {
    return $res->content;
  }
  $self->{error} = {status => $res->status_line, content => $res->content};
  return;
}

=head3 _validate_borrower

Given a borrower cardnumber, identify the borrower and check their eligability
to submit requests. Return an arrayref of the borrower match count followed by
the first borrowers details.

=cut

sub _validate_borrower {

  # Perform cardnumber search.  If no results, perform surname search.
  # Return ( 0, undef ), ( 1, $brw ) or ( n, $brws )
  my ($input, $action) = @_;
  my $patrons = Koha::Patrons->new;
  my ($count, $brw);
  my $query = {cardnumber => $input};
  $query = {borrowernumber => $input} if ($action eq 'search_cont');

  my $brws = $patrons->search($query);
  $count = $brws->count;
  my @criteria = qw/ surname firstname end /;
  while ($count == 0) {
    my $criterium = shift @criteria;
    return (0, undef) if ("end" eq $criterium);
    $brws = $patrons->search({$criterium => $input});
    $count = $brws->count;
  }
  if ($count == 1) {
    $brw = $brws->next;
  }
  else {
    $brw = $brws;    # found multiple results
  }
  return ($count, $brw);
}

=head3 _add_from_breeding

  my $record = $self->_add_from_breeding($breedingid);

Given a MARCBreedingID, we should lookup the record from the reserviour, add it
to the catalogue as a temporary record and return the new records biblionumber
and the remote records biblionumber.

=cut

sub _add_from_breeding {
  my ($self, $breedingid, $framework) = @_;

  # Fetch record from reserviour
  my ($marc, $encoding) = GetImportRecordMarc($breedingid);
  my $record = MARC::Record->new_from_usmarc($marc);

  # Stash the remote biblionumber
  my $remote_id = $record->field('999')->subfield('c');

  # Remove the remote biblionumbers
  my @biblionumbers = $record->field('999');
  $record->delete_field(@biblionumbers);

  # Set the record to suppressed
  $self->_set_suppression($record);

  # Store the record
  my $biblionumber = AddBiblio($record, $framework);

  # Return the new records biblionumber and the remote records biblionumber
  return ($biblionumber, $remote_id);
}

=head3 _set_suppression

  my $result = $self->_set_suppression($record);

Given a MARC::Record, set the suppression bit, return success.

=cut

sub _set_suppression {
  my ($self, $record) = @_;

  my $field942 = $record->field('942');

  # Set Supression (942)
  if (defined $field942) {
    $field942->update(n => '1');
  }
  else {
    my $new942 = MARC::Field->new('942', '', '', n => '1');
    $record->insert_fields_ordered($new942);
  }
  return 1;
}

=head1 AUTHORS

Alex Sassmannshausen <alex.sassmannshausen@ptfs-europe.com>
Martin Renvoize <martin.renvoize@ptfs-europe.com>

=cut

# Contained MockTemplate object is a compatability shim used so we can pass
# a minimal object to Z3950Search and thus use existing Koha breeding and
# configuration functionality.

{

  package MockTemplate;

  use base qw(Class::Accessor);
  __PACKAGE__->mk_accessors("vars");

  sub new {
    my $class = shift;
    my $self = {VARS => {}};
    bless $self, $class;
  }

  sub param {
    my $self = shift;

    # Getter
    if (scalar @_ == 1) {
      my $key = shift @_;
      return $self->{VARS}->{$key};
    }

    # Setter
    while (@_) {
      my $key = shift;
      my $val = shift;

      if    (ref($val) eq 'ARRAY' && !scalar @$val) { $val = undef; }
      elsif (ref($val) eq 'HASH'  && !scalar %$val) { $val = undef; }
      if    ($key) {
        $self->{VARS}->{$key} = $val;
      }
      else {
        warn "Problem = a value of $val has been passed to param without key";
      }
    }
  }
}

1;
