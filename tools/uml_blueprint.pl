#!/usr/bin/env perl
#
# uml_blueprint.pl — generate a PlantUML class diagram from OCaml sources.
#
# Each module (an *.ml / *.mli file) becomes a class:
#   - types -> fields
#   - vals  -> methods (with a best-effort return type)
#
# Edges are DECLARED, not guessed. A signature has no bodies, so a call graph
# cannot be recovered from it, and scraping .ml bodies is a heuristic that lies
# on aliases, opens and functor params. Instead the author states each edge in a
# comment tag, anywhere in the module's .ml/.mli:
#
#   (* @uses  <Module> [-- <note>] *)   solid  A --> B : <note>   (a real call)
#   (* @needs <Module> [<Module>...] *) dashed A ..> B            (type-only)
#
# Example (lib/backend/managers/Lifecycle.mli):
#   (* @uses Object -- calls register/unregister *)
#   (* @needs Path *)
# yields:
#   Lifecycle --> Object : calls register/unregister
#   Lifecycle ..> Path
#
# A tag naming an unknown module is reported on stderr (typo guard for CI).
#
# Usage: perl tools/uml_blueprint.pl --src lib --out docs/architecture.puml

use strict;
use warnings;
use File::Find ();
use Getopt::Long ();

my $src   = 'lib';
my $out   = '-';
my $title = 'RNT Architecture';
my $strict   = 0;    # --strict:   exit non-zero if a tag names an unknown module
my $no_notes = 0;    # --no-notes: drop @uses edge labels (pristine edges)
Getopt::Long::GetOptions(
  'src=s'    => \$src,
  'out=s'    => \$out,
  'title=s'  => \$title,
  'strict'   => \$strict,
  'no-notes' => \$no_notes,
) or die "usage: $0 [--src DIR] [--out FILE] [--title STR] [--strict] [--no-notes]\n";

# ---------------------------------------------------------------------------
# 1. Discover modules. A module is a capitalised *.ml / *.mli basename.
# ---------------------------------------------------------------------------
my %mod;    # base => { ml => path, mli => path }
File::Find::find(
  sub {
    return unless -f $_;
    return unless /\A([A-Z][A-Za-z0-9_']*)\.(mli?)\z/;
    $mod{$1}{ $2 eq 'mli' ? 'mli' : 'ml' } = $File::Find::name;
  },
  $src
);
my %known = map { $_ => 1 } keys %mod;
die "no OCaml modules found under $src\n" unless %known;

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------
sub slurp {
  my ($f) = @_;
  open my $fh, '<', $f or die "$f: $!\n";
  local $/;
  return <$fh>;
}

# Remove OCaml comments (nested (* *)) and string literals, so a keyword inside
# either cannot masquerade as a member. Tags are read from the RAW text; members
# from this stripped text.
sub strip {
  my ($s) = @_;
  my ($i, $n, $depth, $keep) = (0, length $s, 0, '');
  while ($i < $n) {
    my $two = substr($s, $i, 2);
    if ($depth == 0 && $two eq '(*') { $depth = 1; $i += 2; next; }
    if ($depth > 0) {
      if    ($two eq '(*') { $depth++; $i += 2; next; }
      elsif ($two eq '*)') { $depth--; $i += 2; next; }
      $i++;
      next;
    }
    my $c = substr($s, $i, 1);
    if ($c eq '"') {    # skip a string literal, honouring \" escapes
      $i++;
      while ($i < $n) {
        my $d = substr($s, $i, 1);
        if    ($d eq '\\') { $i += 2; next; }
        elsif ($d eq '"')  { $i++; last; }
        $i++;
      }
      $keep .= ' ';
      next;
    }
    $keep .= $c;
    $i++;
  }
  return $keep;
}

sub clean_name {          # strip the parens off an operator val, e.g. ( |=| )
  my ($n) = @_;
  $n =~ s/\A\(\s*//;
  $n =~ s/\s*\)\z//;
  return $n;
}

sub ret_of {              # best-effort return type: text after the last arrow
  my ($s) = @_;
  $s =~ s/\s+/ /g;
  $s = $1 if $s =~ /.*->\s*(.*)\z/s;
  $s =~ s/[(){}:]/ /g;                    # keep it a valid PlantUML label
  $s =~ s/\s+/ /g;
  $s =~ s/\A\s+|\s+\z//g;
  $s = substr($s, 0, 57) . '...' if length $s > 60;
  return $s;
}

sub uniq {
  my %seen;
  return grep { !$seen{$_}++ } @_;
}

# Members from a signature (.mli).
sub parse_sig {
  my ($t) = @_;
  my (@types, @vals);
  while ($t =~ /(?<![\w'])(?:type|and)\s+(?:\([^)]*\)\s+|'[\w']+\s+)*([a-z_][\w']*)/g) {
    push @types, $1;
  }
  while ($t =~ /(?<![\w'])val\s+(\([^)]*\)|[a-z_][\w']*)\s*:\s*
                (.*?)(?=(?:\bval\b|\btype\b|\band\b|\bmodule\b|\binclude\b|\bend\b)|\z)/gsx) {
    push @vals, [ clean_name($1), ret_of($2) ];
  }
  return (\@types, \@vals);
}

# Members from an implementation (.ml) — used when a module has no .mli.
# Only column-0 `let`/`type` count, so local bindings are ignored.
sub parse_impl {
  my ($t) = @_;
  my (@types, @vals);
  while ($t =~ /(?<![\w'])(?:type|and)\s+(?:\([^)]*\)\s+|'[\w']+\s+)*([a-z_][\w']*)/g) {
    push @types, $1;
  }
  while ($t =~ /(?:\A|\n)let\s+(?:rec\s+)?(\([^)]*\)|[a-z_][\w']*)/g) {
    push @vals, [ clean_name($1), '' ];
  }
  return (\@types, \@vals);
}

# Declared edges from tags in the RAW text of a module.
#   @composes B [-- note] -> ('composes', B, note)   functor param / application
#   @uses     B [-- note] -> ('uses', B, note)       declared call
#   @needs    B [C ...]   -> ('needs', B, undef)     type-only coupling
my $warned = 0;
sub parse_tags {
  my ($raw, $self) = @_;
  my @edges;
  for my $kw (qw(composes uses)) {
    while ($raw =~ /\@$kw\s+([A-Z][\w']*)\s*(?:--\s*(.+?))?\s*(?:\*\)|\R|\z)/g) {
      my ($b, $note) = ($1, $2);
      $note =~ s/\s+\z// if defined $note;
      push @edges, [ $kw, $b, $note ];
    }
  }
  while ($raw =~ /\@needs\s+((?:[A-Z][\w']*[,\s]*)+)/g) {
    push @edges, [ 'needs', $_, undef ] for ($1 =~ /([A-Z][\w']*)/g);
  }
  for my $e (@edges) {
    my $b = $e->[1];
    if (!$known{$b}) {
      warn "$self: \@$e->[0] names unknown module '$b'\n";
      $warned++;
    }
  }
  return grep { $known{ $_->[1] } && $_->[1] ne $self } @edges;
}

# ---------------------------------------------------------------------------
# 2. Build classes and edges.
# ---------------------------------------------------------------------------
my (%types, %vals, %edges);
for my $m (keys %mod) {
  my $raw_sig  = $mod{$m}{mli} ? slurp($mod{$m}{mli}) : '';
  my $raw_impl = $mod{$m}{ml}  ? slurp($mod{$m}{ml})  : '';

  if ($raw_sig ne '') { ($types{$m}, $vals{$m}) = parse_sig(strip($raw_sig)); }
  else                { ($types{$m}, $vals{$m}) = parse_impl(strip($raw_impl)); }

  # Tags may live in either file.
  $edges{$m} = [ parse_tags($raw_sig, $m), parse_tags($raw_impl, $m) ];
}

# ---------------------------------------------------------------------------
# 3. Emit PlantUML.
# ---------------------------------------------------------------------------
my $fh;
if ($out eq '-') { $fh = \*STDOUT; }
else { open $fh, '>', $out or die "$out: $!\n"; }

print {$fh} "\@startuml\n";
print {$fh} "!theme toy\n";
print {$fh} "title $title\n";
print {$fh} "hide empty members\n";
print {$fh} "skinparam classAttributeIconSize 0\n";
# Orthogonal routing: straight segments with right-angle turns instead of
# curved splines. Use "polyline" for straight-but-diagonal edges instead.
print {$fh} "skinparam linetype ortho\n";
# Keep the graph compact so it does not shrink to unreadable when fit to width,
# but leave enough gap that ortho channels do not merge. Larger font offsets the
# tighter packing.
print {$fh} "skinparam nodesep 30\n";
print {$fh} "skinparam ranksep 50\n";
print {$fh} "skinparam defaultFontSize 15\n";
print {$fh} "left to right direction\n\n";

for my $m (sort keys %mod) {
  print {$fh} "class $m <<module>> {\n";
  my @t = uniq(@{ $types{$m} });
  if (@t) {
    print {$fh} "  .. types ..\n";
    print {$fh} "  +$_\n" for @t;
  }
  my @v = uniq(map { $_->[0] } @{ $vals{$m} });
  my %ret = map { $_->[0] => $_->[1] } @{ $vals{$m} };
  if (@v) {
    print {$fh} "  .. values ..\n";
    for my $name (@v) {
      if ($name =~ /\A[a-z_][\w']*\z/) {
        print {$fh} $ret{$name} ? "  +$name() : $ret{$name}\n" : "  +$name()\n";
      }
      else { print {$fh} "  +\"$name\"\n"; }    # operator, rendered flat
    }
  }
  print {$fh} "}\n\n";
}

# One edge per pair: the strongest declared relation wins.
#   composes (3) *--   >   uses (2) -->   >   needs (1) ..>
my %rank = (composes => 3, uses => 2, needs => 1);
my %best;    # "from|to" => [kind, note]
for my $from (sort keys %mod) {
  for my $e (@{ $edges{$from} }) {
    my ($kind, $to, $note) = @$e;
    my $key = "$from|$to";
    next if $best{$key} && $rank{ $best{$key}[0] } >= $rank{$kind};
    $best{$key} = [ $kind, $note ];
  }
}
for my $key (sort keys %best) {
  my ($from, $to) = split /\|/, $key;
  my ($kind, $note) = @{ $best{$key} };
  my $arrow = $kind eq 'composes' ? '*--' : $kind eq 'uses' ? '-->' : '..>';
  my $label = (!$no_notes && defined $note && $note ne '') ? " : $note" : '';
  print {$fh} "$from $arrow $to$label\n";
}

print {$fh} "\nlegend right\n";
print {$fh} "  diamond A *-- B : functor composition (\@composes)\n";
print {$fh} "  solid   A --> B : declared call (\@uses)\n";
print {$fh} "  dashed  A ..> B : type-only coupling (\@needs)\n";
print {$fh} "endlegend\n";
print {$fh} "\@enduml\n";

close $fh if $out ne '-';

exit 2 if $strict && $warned;
