<?php
/**
 * This script helps reduce the stack frame of an XDebug trace file
 * into a lesser level. Right now there is no way to do this
 * natively with XDebug although there is an open request for the
 * feature here http://bugs.xdebug.org/view.php?id=722
 *
 * You can use this script like:
 *
 * php process-xdebug-trace.php -f /path/to/trace.file -d frame-depth
 *
 * At the moment this is only able to recognize text based trace files
 * with default collect params.
 */

$params = getArgs($_SERVER['argv']);
$f = (isset($params['f']) AND $params['f']) ? $params['f'] : false;
$d = (isset($params['d']) AND $params['d']) ? (int) $params['d'] : false;

if(!$f OR !$d) { die('Both XDebug trace file and depth level parameters are required.'); }
if(!is_file($f) OR !is_readable($f)) { die("$f is not a valid file or no permissions to read the file."); }
if(!is_int($d) OR $d < 1) { die("Stack frame depth is not a valid numeric value."); }

$fd = fopen($f, 'r');
if(!$fd) { die("Failed to open $f for reading."); }

/* Baseline count of spaces */
$base_spc = 0;
$p_tme = 0;
$p_vsz = 0;
$b_tme = 0;
$b_vsz = 0;
$spc = 0;

print "Processing $f with stack frame depth of $d\n\n";

while(($ln = fgets($fd, 8192)) !== false) {
    $ln = trim($ln, "\n");
    if(strstr($ln, 'TRACE') OR !strlen($ln)) continue;

    if(!$base_spc AND strstr($ln, '{main}()')) {
        $base_spc = substr_count($ln, ' ');
    }
    else {
        $spc = substr_count($ln, ' ');
    }

    if(!$base_spc) continue;

    preg_match_all('/(\d+\.\d+)\s+(\d+)/', $ln, $v);
    $tme = $v[1][0];
    $vsz = $v[2][0];

if(!isset($v[1][0])) var_dump($ln);

    if($spc <= ($base_spc + ($d * 2))) {
        printf("%.4f %' 16d %s\n", ($tme - $b_tme), ($vsz - $b_vsz), $ln);
        $b_tme = $tme;
        $b_vsz = $vsz;
    }

    $p_tme = $tme;
    $p_vsz = $vsz;
}
fclose($fd);

/* Thanks to http://www.php.net/manual/en/features.commandline.php#78651 */
function getArgs($args) {
 $out = array();
 $last_arg = null;
    for($i = 1, $il = sizeof($args); $i < $il; $i++) {
        if( (bool)preg_match("/^--(.+)/", $args[$i], $match) ) {
         $parts = explode("=", $match[1]);
         $key = preg_replace("/[^a-z0-9]+/", "", $parts[0]);
            if(isset($parts[1])) {
             $out[$key] = $parts[1];    
            }
            else {
             $out[$key] = true;    
            }
         $last_arg = $key;
        }
        else if( (bool)preg_match("/^-([a-zA-Z0-9]+)/", $args[$i], $match) ) {
            for( $j = 0, $jl = strlen($match[1]); $j < $jl; $j++ ) {
             $key = $match[1]{$j};
             $out[$key] = true;
            }
         $last_arg = $key;
        }
        else if($last_arg !== null) {
         $out[$last_arg] = $args[$i];
        }
    }
 return $out;
}
?>
