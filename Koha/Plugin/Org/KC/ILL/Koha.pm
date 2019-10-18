package Koha::Plugin::Org::KC::ILL::Koha;

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# This program comes with ABSOLUTELY NO WARRANTY;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use Mojo::JSON qw(decode_json);
use YAML;

our $VERSION = "{VERSION}";

our $metadata = {
    name            => 'ILL plugin Koha <->Koha',
    author          => 'Koha Community',
    date_authored   => '2018-09-10',
    date_updated    => "2019-10-02",
    minimum_version => '19.06',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'ILL plugin Koha <->Koha'
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'configure.tt' });

    unless ( scalar $cgi->param('save') ) {

        ## Grab the values we already have for our settings, if any exist
        $template->param(
            configuration => $self->retrieve_data('configuration'),
        );

        $self->output_html( $template->output() );
    }
    else {
        $self->store_data(
            {
                configuration => scalar $cgi->param('configuration'),
            }
        );
        $template->param(
            configuration => $self->retrieve_data('configuration'),
        );
        $self->output_html( $template->output() );
    }
}

sub configuration {
    my ($self) = @_;

    my $configuration;
    eval { $configuration = YAML::Load( $self->retrieve_data('configuration') . "\n\n" ); };
    die($@) if $@;

    return $configuration;
}

1;
