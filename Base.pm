package Koha::Illbackends::Koha::Base;

# Copyright PTFS Europe 2014
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

=head1 NAME

Koha::Illrequest::Backend::Dummy - Koha ILL Backend: Dummy

=head1 SYNOPSIS

Koha ILL implementation for the "Dummy" backend.

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
      request    => $request,
      other      => $other,
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
definition consisting of {
  $name => {
    SRU => 'sru_base_uri',
    ILSDI => 'ilsdi_base_uri',
    user => 'remote_user_name',
    password => 'remote_password',
  }
}.

=head1 API

=head2 Class Methods

=cut

=head3 new

  my $backend = Koha::Illrequest::Backend::Dummy->new;

=cut

sub new {
    # -> instantiate the backend
    my ( $class ) = @_;
    my $self = {
        # FIXME: This should be loaded from a configuration.  We should allow
        # multiple targets.
        targets => {
            'Demo Koha Instance' => {
                SRU => 'http://demo.koha-ptfs.eu:9998/biblios',
                ILSDI => 'https://demo.koha-ptfs.eu/cgi-bin/koha/ilsdi.pl',
            },
        },
    };
    bless( $self, $class );
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
    my ( $self, $request ) = @_;
    my $attrs = $request->illrequestattributes;
    return {
        ID     => $attrs->find({ type => 'bib_id' })->value,
        Title  => $attrs->find({ type => 'title' })->value,
        Author => $attrs->find({ type => 'author' })->value,
        Target => $attrs->find({ type => 'target' })->value,
    }
}

=head3 capabilities

    $capability = $backend->capabilities($name);

Return the sub implementing a capability selected by NAME, or 0 if that
capability is not implemented.

=cut

sub capabilities {
    my ( $self, $name ) = @_;
    my $capabilities = {
        # We don't implement unmediated for now
        # unmediated_ill => sub { $self->confirm(@_); }
    };
    return $capabilities->{$name};
}

=head3 status_graph

=cut

sub status_graph {
    return {};
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
    my ( $self, $params ) = @_;
    my $other = $params->{other};
    my $stage = $other->{stage};
    if ( !$stage || $stage eq 'init' ) {
        # We simply need our template .INC to produce a search form.
        return {
            error   => 0,
            status  => '',
            message => '',
            method  => 'create',
            stage   => 'search_form',
            value   => $params,
        };
    } elsif ( $stage eq 'search_form' ) {
	# Received search query in 'other'; perform search...
        my ( $brw_count, $brw )
            = _validate_borrower($other->{'cardnumber'}, $stage);
        my $result = {
            status  => "",
            message => "",
            error   => 1,
            value   => {},
            method  => "create",
            stage   => "init",
        };
        if ( _fail($other->{'branchcode'}) ) {
            $result->{status} = "missing_branch";
            $result->{value} = $params;
            return $result;
        } elsif ( !Koha::Libraries->find($other->{'branchcode'}) ) {
            $result->{status} = "invalid_branch";
            $result->{value} = $params;
            return $result;
        } elsif ( $brw_count == 0 ) {
            $result->{status} = "invalid_borrower";
            $result->{value} = $params;
            return $result;
        } elsif ( $brw_count > 1 ) {
            # We must select a specific borrower out of our options.
            $params->{brw} = $brw;
            $result->{value} = $params;
            $result->{stage} = "borrowers";
            $result->{error} = 0;
            return $result;
        } else {
            # We perform the search!
            $other->{borrowernumber} = $brw->borrowernumber;
            return $self->_search($params);
        }

    } elsif ( $stage eq 'search_results' ) {
        my $other = $params->{other};

        my $request_details = {
            title => $other->{title},
            bib_id => $other->{bib_id},
            author => $other->{author},
            target => $other->{target},
        };
        my $brwnum = $other->{borrowernumber};
        # ...Populate Illrequest
        my $request = $params->{request};
        $request->borrowernumber($brwnum);
        $request->branchcode($other->{branchcode});
        $request->status('NEW');
	$request->backend($other->{backend});
        $request->placed(DateTime->now);
        $request->updated(DateTime->now);
        $request->store;
        # ...Populate Illrequestattributes
        while ( my ( $type, $value ) = each %{$request_details} ) {
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
    } else {
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

=head3 confirm

  my $response = $backend->confirm({
      request    => $requestdetails,
      other      => $other,
  });

Confirm the placement of the previously "selected" request (by using the
'create' method).

In this case we will generally use $request.
This will be supplied at all times through Illrequest.  $other may be supplied
using templates.

=cut

sub confirm {
    # -> confirm placement of the ILL order
    my ( $self, $params ) = @_;
    # Turn Illrequestattributes into a plain hashref
    my $value = {};
    my $attributes = $params->{request}->illrequestattributes;
    foreach my $attr (@{$attributes->as_list}) {
        $value->{$attr->type} = $attr->value;
    };
    my $target = $self->{targets}->{$value->{target}};

    # Submit request to backend...

    # Authentication:
    my $url = URI->new($target->{ILSDI});
    my $key_pairs  = {
        'service' => 'AuthenticatePatron',
        'username' => $target->{user},
        'password' => $target->{password},
    };
    $url->query_form( $key_pairs );
    my $rsp = $self->_request( { method => 'GET', url => $url } );
    # FIXME: Should do error handling!
    my $doc = XML::LibXML->load_xml(string => $rsp);
    my $query = "//AuthenticatePatron/id/text()";
    my $id = ${$doc->findnodes($query)}[0]->data;

    # Place request
    $url = URI->new($target->{ILSDI});
    $key_pairs  = {
        'service' => 'HoldTitle',
        'patron_id' => $id,
        'bib_id' => $value->{bib_id},
        'request_location' => '127.0.0.1',
    };
    $url->query_form( $key_pairs );
    $rsp = $self->_request( { method => 'GET', url => $url } );
    my $doc = XML::LibXML->load_xml(string => $rsp);
    my $query = "//HoldTitle/pickup_location/text()";
    die("Placing hold failed:", $rsp) if !${$doc->findnodes($query)}[0];

    my $request = $params->{request};
    $request->cost("0 GBP");
    $request->orderid($value->{bib_id});
    $request->status("REQ");
    $request->store;
    # ...then return our result:
    return {
        error    => 0,
        status   => '',
        message  => '',
        method   => 'confirm',
        stage    => 'commit',
        next     => 'illview',
        value    => $value,
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
    my ( $self, $params ) = @_;
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
      request    => $requestdetails,
      other      => $other,
  });

We will attempt to cancel a request that was confirmed.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub cancel {
    # -> request an already 'confirm'ed ILL order be cancelled
    my ( $self, $params ) = @_;
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
      request    => $requestdetails,
      other      => $other,
  });

We will try to retrieve the status of a specific request.

We will generally use $request.  This will be supplied at all times through
Illrequest.  $other may be supplied using templates.

=cut

sub status {
    # -> request the current status of a confirmed ILL order
    my ( $self, $params ) = @_;
    return {
        error   => 1,
        status  => 404,
        message => "Not Implemented",
        method  => 'status',
        stage   => 'fake',
        value   => {},
    };
}

=head3 search

    my $results = $bldss->search($query, $opts);

Return an array of Record objects.

The optional OPTS parameter specifies additional options to be passed to the
API. For now the options we use in the ILL Module are:
 max_results -> SearchRequest.maxResults,
 start_rec   -> SearchRequest.start,
 isbn        -> SearchRequest.Advanced.isbn
 issn        -> SearchRequest.Advanced.issn
 title       -> SearchRequest.Advanced.title
 author      -> SearchRequest.Advanced.author
 type        -> SearchRequest.Advanced.type
 general     -> SearchRequest.Advanced.general

We simply pass the options hashref straight to the backend.

=cut

sub _search {
    my ( $self, $params ) = @_;
    my $other = $params->{other};
    my $query = $other->{query};
    my $borrowernumber = $other->{borrowernumber};
    my $brw = Koha::Patrons->find($borrowernumber);
    my $branch = $other->{branchcode};
    my $backend = $other->{backend};
    # FIXME: We ignore opts currently
    my %opts = map { $_ => $other->{$_} }
        qw/ search max_results start_rec /;
    my $opts = \%opts;

    $opts->{max_results} = 10 unless $opts->{max_results};
    $opts->{start_rec} = 1 unless $opts->{start_rec};

    my $results = [];

    my $searches = {};
    foreach my $target ( keys %{$self->{targets}} ) {
        my $importer = Catmandu::Importer::SRU->new(
            base => $self->{targets}->{$target}->{SRU},
            query => $opts->{search},
            recordSchema => 'marcxml',
            parser => 'marcxml',
        );
        # use Data::Dump qw/dump/;
        # die dump($importer->next);
        my $fixer = Catmandu->fixer('
marc_map(245, title);
marc_map(100a, author);
marc_map(999d, bib_id);
retain(title, bib_id, author)');
        $searches->{$target} = $fixer->fix($importer)->to_array;
    }

    # Perform the search in the API
    my $response = {
        status => 200,
        message => "",
        error => 0,
        value => $searches,
    };

    # Augment Response with standard values
    $response->{method} = "create";
    $response->{stage} = "search_results";
    $response->{borrowernumber} = $borrowernumber;
    $response->{cardnumber} = $brw->cardnumber;
    $response->{branchcode} = $branch;
    $response->{backend} = $backend;
    $response->{query} = $opts;
    $response->{params} = $params;

    my $count = 0;
    foreach my $n ( values $searches ) {
        $count += @{$n};
    }
    $response->{count} = $count;

    # Return search results
    return $response;
}

=head3 _fail

=cut

sub _fail {
    my @values = @_;
    foreach my $val ( @values ) {
        return 1 if (!$val or $val eq '');
    }
    return 0;
}

sub _request {
    my ( $self, $param ) = @_;
    my $method     = $param->{method};
    my $url        = $param->{url};
    my $content    = $param->{content};
    my $additional = $param->{additional};

    my $req = HTTP::Request->new( $method => $url );

    # add content if specified
    if ($content) {
        $req->content($content);
        $req->header('Content-Type' => 'text/xml');
    }

    my $ua = LWP::UserAgent->new;
    my $res = $ua->request($req);
    if ( $res->is_success ) {
        return $res->content;
    }
    $self->{error} = {
        status  => $res->status_line,
        content => $res->content
    };
    return;
}

=head3 _validate_borrower

=cut

sub _validate_borrower {
    # Perform cardnumber search.  If no results, perform surname search.
    # Return ( 0, undef ), ( 1, $brw ) or ( n, $brws )
    my ( $input, $action ) = @_;
    my $patrons = Koha::Patrons->new;
    my ( $count, $brw );
    my $query = { cardnumber => $input };
    $query = { borrowernumber => $input } if ( $action eq 'search_cont' );

    my $brws = $patrons->search( $query );
    $count = $brws->count;
    my @criteria = qw/ surname firstname end /;
    while ( $count == 0 ) {
        my $criterium = shift @criteria;
        return ( 0, undef ) if ( "end" eq $criterium );
        $brws = $patrons->search( { $criterium => $input } );
        $count = $brws->count;
    }
    if ( $count == 1 ) {
        $brw = $brws->next;
    } else {
        $brw = $brws;           # found multiple results
    }
    return ( $count, $brw );
}

=head1 AUTHOR

Alex Sassmannshausen <alex.sassmannshausen@ptfs-europe.com>

=cut

1;
