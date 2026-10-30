#!/usr/bin/env perl
# Validate static IPv4 settings and render per-VM NoCloud seed files.
# Uses the Perl YAML/IP libraries supplied by Proxmox VE 8 and later.
package LocalSeed;

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray Configure);
use JSON::PP qw(decode_json encode_json);
use NetAddr::IP;
use Scalar::Util qw(blessed refaddr);
use Storable qw(dclone);
use YAML::XS 0.84 ();

# Parse a canonical dotted IPv4 address and reject non-unicast endpoints.
# Args: address string and its human-readable field name.
# Returns: a NetAddr::IP host object.
# Raises: an error for malformed, reserved, loopback, or multicast addresses.
sub parse_unicast {
    my ($address, $label) = @_;
    die "$label must be a dotted IPv4 address\n"
        if !defined($address) || ref($address)
        || $address !~ /\A(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){3}\z/;
    my @octets = split /\./, $address;
    die "$label must be a usable unicast IPv4 address\n"
        if grep { $_ > 255 } @octets;
    die "$label must be a usable unicast IPv4 address\n"
        if $octets[0] == 0 || $octets[0] == 127 || $octets[0] >= 224;
    my $parsed = NetAddr::IP->new("$address/32");
    die "$label must be a usable unicast IPv4 address\n" if !$parsed;
    return $parsed;
}

# Validate the address, route, and resolver as a single network contract.
# Args: host IPv4/CIDR, gateway IPv4, and optional DNS IPv4.
# Returns: a hash of canonical ip, gateway, dns, and prefix values.
# Raises: an error for invalid addresses or incompatible subnet relationships.
sub parse_network {
    my ($ip, $gateway, $dns) = @_;
    die "IP must include a numeric CIDR prefix, for example 10.0.0.34/24\n"
        if !defined($ip) || ref($ip) || $ip !~ /\A([0-9.]+)\/([0-9]{1,2})\z/;
    my ($host, $prefix) = ($1, 0 + $2);
    die "IP CIDR prefix must be between 0 and 32\n" if $prefix > 32;
    my $address = parse_unicast($host, 'IP');
    my $route = parse_unicast($gateway, 'Gateway');
    my $resolver = parse_unicast(defined($dns) ? $dns : $gateway, 'DNS');
    my $subnet = NetAddr::IP->new("$host/$prefix");
    die "Invalid IPv4 subnet\n" if !$subnet;
    if ($prefix <= 30) {
        die "IP must be a host address, not the subnet or broadcast address\n"
            if $host eq $subnet->network->addr || $host eq $subnet->broadcast->addr;
        die "Gateway must be a host address, not the subnet or broadcast address\n"
            if $gateway eq $subnet->network->addr || $gateway eq $subnet->broadcast->addr;
    }
    die "Gateway must differ from the host IP\n" if $host eq $gateway;
    # /31 has two usable peers; /32 routes explicitly mark the gateway on-link.
    die "Gateway must be within the IP subnet (except for /32)\n"
        if $prefix != 32 && !$subnet->network->contains($route);
    return {
        ip => $address->addr . "/$prefix",
        gateway => $route->addr,
        dns => $resolver->addr,
        prefix => $prefix,
    };
}

# Validate and normalize a MAC used to match an installation interface.
# Args: MAC string in six colon-separated hexadecimal octets.
# Returns: the lowercase unicast MAC.
# Raises: an error for invalid, zero, or multicast MAC addresses.
sub validate_mac {
    my ($mac) = @_;
    die "Adapter needs one explicit MAC address\n"
        if !defined($mac) || ref($mac) || $mac !~ /\A(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\z/;
    $mac = lc $mac;
    die "Adapter needs a nonzero unicast MAC address\n"
        if (hex(substr($mac, 0, 2)) & 1) || $mac eq '00:00:00:00:00:00';
    return $mac;
}

# Resolve one Proxmox NIC to its guest-visible MAC.
# Args: qm config text and a Proxmox adapter key such as net0.
# Returns: a lowercase unicast MAC address.
# Raises: an error for missing, duplicate, disabled, or malformed adapters.
sub interface_mac {
    my ($config, $interface) = @_;
    die "VM configuration and interface must be strings\n"
        if !defined($config) || ref($config) || !defined($interface) || ref($interface);
    die "Interface must be a Proxmox network key such as net0\n"
        if $interface !~ /\Anet[0-9]+\z/;
    my @lines = $config =~ /^\Q$interface\E:[ \t]*(.*)$/mg;
    die "Expected one configured $interface adapter\n" if @lines != 1;
    my %fields;
    for my $field (split /,/, $lines[0], -1) {
        my ($key, $value) = split /=/, $field, 2;
        die "Malformed $interface adapter configuration\n"
            if !defined($value) || exists($fields{$key});
        $fields{$key} = $value;
    }
    die "Adapter $interface has its link disabled\n"
        if lc($fields{link_down} // '0') !~ /\A(?:0|off|false|no)\z/;
    my %models = map { $_ => 1 } qw(
        e1000 e1000-82540em e1000-82544gc e1000-82545em e1000e
        i82551 i82557b i82559er ne2k_isa ne2k_pci pcnet rtl8139 virtio vmxnet3
    );
    my @macs = map { $fields{$_} } grep { $models{$_} } keys %fields;
    die "Adapter $interface needs one explicit MAC address\n" if @macs != 1;
    return validate_mac($macs[0]);
}

# Construct the network mapping shared by cloud-init and the installer.
# Args: network settings hash and a unicast MAC address.
# Returns: a Netplan version 2 mapping with explicit YAML booleans.
# Raises: an error if either argument fails its boundary contract.
sub build_network {
    my ($settings, $mac) = @_;
    die "Settings must be a network settings mapping\n"
        if ref($settings) ne 'HASH' || blessed($settings);
    $settings = parse_network($settings->{ip}, $settings->{gateway}, $settings->{dns});
    $mac = validate_mac($mac);
    my $route = { to => 'default', via => $settings->{gateway} };
    $route->{'on-link'} = JSON::PP::true if $settings->{prefix} == 32;
    return {
        version => 2,
        ethernets => {
            install_nic => {
                match => { macaddress => $mac },
                dhcp4 => JSON::PP::false,
                addresses => [$settings->{ip}],
                routes => [$route],
                nameservers => { addresses => [$settings->{dns}] },
            },
        },
    };
}

# Read bytes without Perl's implicit character conversions.
# Args: a filesystem path.
# Returns: file bytes, suitable for YAML::XS and JSON UTF-8 decoders.
# Raises: an error if the file cannot be opened, read, or closed.
sub read_file {
    my ($path) = @_;
    die "File path must be a nonempty string\n" if !defined($path) || ref($path) || !length($path);
    open my $file, '<:raw', $path or die "Cannot read $path: $!\n";
    local $/;
    my $content = <$file>;
    die "Cannot read $path: $!\n" if !defined($content) && !eof($file);
    close $file or die "Cannot close $path: $!\n";
    return $content // '';
}

# Restrict loaded YAML to plain data while allowing shared nonrecursive aliases.
# Args: a loaded value, active reference IDs, and already-validated reference IDs.
# Returns: nothing on success.
# Raises: an error for objects, code, regexes, or recursive aliases.
sub validate_plain_data {
    my ($value, $active, $validated) = @_;
    return if !ref($value) || JSON::PP::is_bool($value);
    die "YAML must contain only plain mappings, lists, and scalar values\n"
        if blessed($value) || (ref($value) ne 'HASH' && ref($value) ne 'ARRAY');
    my $id = refaddr($value);
    die "Recursive YAML aliases are not supported\n" if $active->{$id};
    return if $validated->{$id};
    local $active->{$id} = 1;
    my @children = ref($value) eq 'HASH' ? values %$value : @$value;
    validate_plain_data($_, $active, $validated) for @children;
    $validated->{$id} = 1;
}

# Load one YAML mapping in safe mode, preserving booleans and nulls.
# Args: UTF-8 bytes and a name for diagnostics.
# Returns: the parsed plain mapping.
# Raises: an error for malformed YAML, duplicate keys, extra documents, or unsafe types.
sub load_mapping {
    my ($bytes, $name) = @_;
    local $YAML::XS::Boolean = 'JSON::PP';
    local $YAML::XS::LoadBlessed = 0;
    local $YAML::XS::LoadCode = 0;
    local $YAML::XS::UseCode = 0;
    local $YAML::XS::ForbidDuplicateKeys = 1;
    # YAML::XS safe mode strips class tags; it never constructs tagged objects.
    my @documents = YAML::XS::Load($bytes);
    die "$name must contain exactly one YAML document\n" if @documents != 1;
    validate_plain_data($documents[0], {}, {});
    die "$name must contain a mapping\n" if ref($documents[0]) ne 'HASH';
    return $documents[0];
}

# Produce a collision-resistant identifier without an external UUID command.
# Args: none.
# Returns: 32 lowercase hexadecimal characters from the OS random source.
# Raises: an error if sufficient random bytes cannot be obtained.
sub new_id {
    open my $random, '<:raw', '/dev/urandom' or die "Cannot open OS random source: $!\n";
    my $bytes = '';
    while (length($bytes) < 16) {
        my $read = read($random, my $part, 16 - length($bytes));
        die "Cannot read OS random source\n" if !defined($read) || !$read;
        $bytes .= $part;
    }
    close $random or die "Cannot close OS random source: $!\n";
    return unpack('H*', $bytes);
}

# Render copies of the selected profile with static networking and per-VM metadata.
# Args: input/output directories, VMID, qm config text, NIC key, and settings hash.
# Returns: nothing; writes user-data, meta-data, network-config, and vendor-data.
# Raises: an error for invalid input or an occupied output directory.
sub render_seed {
    my ($input, $output, $vmid, $config, $interface, $settings) = @_;
    die "VMID must be a positive integer\n"
        if !defined($vmid) || ref($vmid) || $vmid !~ /\A[0-9]+\z/ || $vmid == 0;
    for my $path ($input, $output) {
        die "Input and output directories must be nonempty path strings\n"
            if !defined($path) || ref($path) || !length($path);
    }
    die "Input directory does not exist: $input\n" if !-d $input;
    if (-e $output) {
        die "Output directory must be empty\n" if !-d $output;
        die "Input and output directories must differ\n" if abs_path($input) eq abs_path($output);
        opendir my $directory, $output or die "Cannot read output directory: $!\n";
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $directory;
        closedir $directory or die "Cannot close output directory: $!\n";
        die "Output directory must be empty\n" if @entries;
    }
    my $user_bytes = read_file(File::Spec->catfile($input, 'user-data'));
    die "user-data must begin with a #cloud-config header\n" if $user_bytes !~ /\A#cloud-config\n/;
    my $user = load_mapping($user_bytes, 'user-data');
    my $metadata = load_mapping(read_file(File::Spec->catfile($input, 'meta-data')), 'meta-data');
    my $autoinstall = $user->{autoinstall};
    die "user-data must contain autoinstall version 1\n"
        if ref($autoinstall) ne 'HASH' || !defined($autoinstall->{version})
        || ref($autoinstall->{version}) || encode_json($autoinstall->{version}) ne '1';
    die "autoinstall must contain a storage mapping\n" if ref($autoinstall->{storage}) ne 'HASH';
    my $sections = exists($autoinstall->{'interactive-sections'})
        ? $autoinstall->{'interactive-sections'} : [];
    die "interactive-sections must be a list of strings\n"
        if ref($sections) ne 'ARRAY'
        || grep { !defined($_) || ref($_) || encode_json($_) !~ /\A"/ } @$sections;
    die "Wildcard interactive-sections cannot be combined with static networking\n"
        if grep { $_ eq '*' } @$sections;
    my $network = build_network($settings, interface_mac($config, $interface));
    $autoinstall->{network} = dclone($network);
    $autoinstall->{'interactive-sections'} = [grep { $_ ne 'network' } @$sections];
    $metadata->{'instance-id'} = "iid-autoinstall-$vmid-" . new_id();
    # JSON is also valid YAML. Quoting every key and string prevents YAML 1.1
    # readers in cloud-init from reinterpreting strings such as "yes" or "no".
    my $encoder = JSON::PP->new->utf8->canonical->pretty;
    my %documents = (
        'user-data' => "#cloud-config\n" . $encoder->encode($user),
        'meta-data' => $encoder->encode($metadata),
        'network-config' => $encoder->encode($network),
        'vendor-data' => "#cloud-config\n{}\n",
    );
    make_path($output) if !-d $output;
    for my $name (sort keys %documents) {
        my $path = File::Spec->catfile($output, $name);
        open my $file, '>:raw', $path or die "Cannot write $path: $!\n";
        print {$file} $documents{$name} or die "Cannot write $path: $!\n";
        close $file or die "Cannot close $path: $!\n";
    }
}

# Extract the configuration digest without silently accepting invalid JSON shapes.
# Args: UTF-8 JSON bytes from pvesh.
# Returns: the 40-character SHA-1 configuration digest.
# Raises: an error if JSON or the digest is invalid.
sub read_digest {
    my ($bytes) = @_;
    my $config = decode_json($bytes);
    die "Proxmox did not return a valid configuration digest\n"
        if ref($config) ne 'HASH' || !defined($config->{digest}) || ref($config->{digest})
        || $config->{digest} !~ /\A[0-9a-fA-F]{40}\z/;
    return $config->{digest};
}

# Dispatch the small command-line interface and report concise validation errors.
# Args: CLI arguments excluding the program name.
# Returns: zero on success, one on invalid arguments, data, or I/O failures.
sub main {
    my (@args) = @_;
    my $ok = eval {
        my $command = shift(@args) // '';
        if ($command eq 'new-id') {
            die "new-id does not accept arguments\n" if @args;
            print new_id(), "\n";
        } elsif ($command eq 'read-digest') {
            die "read-digest does not accept arguments\n" if @args;
            local $/;
            binmode STDIN, ':raw';
            my $input = <STDIN>;
            print read_digest($input // ''), "\n";
        } elsif ($command eq 'validate-network' || $command eq 'render') {
            my %options;
            Configure('no_auto_abbrev', 'no_ignore_case', 'no_getopt_compat');
            my @specifications = qw(ip=s gateway=s dns=s);
            push @specifications, qw(vm-config=s interface=s vmid=s input-dir=s output-dir=s)
                if $command eq 'render';
            die "Invalid command-line options\n"
                if !GetOptionsFromArray(\@args, \%options, @specifications) || @args;
            for my $required ('ip', 'gateway', $command eq 'render' ? qw(vm-config vmid input-dir output-dir) : ()) {
                die "Missing required option --$required\n" if !defined($options{$required});
            }
            my $settings = parse_network($options{ip}, $options{gateway}, $options{dns});
            render_seed($options{'input-dir'}, $options{'output-dir'}, $options{vmid},
                read_file($options{'vm-config'}), $options{interface} // 'net0', $settings)
                if $command eq 'render';
        } else {
            die "Usage: prepare_local_seed.pl validate-network|render|read-digest|new-id [OPTIONS]\n";
        }
        1;
    };
    if (!$ok) {
        my $error = $@ || 'Unknown error';
        $error =~ s/\s+\z//;
        print STDERR "ERROR: $error\n";
        return 1;
    }
    return 0;
}

exit main(@ARGV) unless caller;
1;
