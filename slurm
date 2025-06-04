#!/usr/bin/env nu

def main [] {
  help main
}

def "main status" [] {
  {
    "Nodes\nstate": (
      sinfo -o "%.10t %.10D %.50N"
        | from ssv
        | rename index count nodes
    ),
    "Nodes\ndown": (
      let nodes = (sinfo -o "%100E %50H %50N"
        | from ssv
        | where reason != none
        | select NODELIST TIMESTAMP REASON
        | rename index time reason
      );
      if ($nodes | is-empty) { "all nodes up" } else { $nodes }
    ),
    "Queue": (
      squeue --noheader --format="%T"
        | lines
        | group-by
        | transpose state count
        | update count {|row| $row.count | length }
        | rename index count
    ),
    "Your\njobs": (
      let jobs = (
        squeue --me -o "%i\t%T\t%P\t%.20j\t%.10M\t%.6D\t%R\t%V"
          | from tsv --trim all
          | insert WHERE {|row|
              if $row.STATE == "RUNNING" {
                  $row."NODELIST(REASON)"
              } else {
                  $'($row.NODES) ($row."NODELIST(REASON)")'
              }
          }
          | update TIME {|row|
              # update time to waiting time
              if $row.state == "PENDING" {
                  let now = date now | format date "%Y-%m-%d %H:%M:%S" | into datetime
                  let submitted = $row.SUBMIT_TIME | into datetime
                  ($now - $submitted) | into duration
              } else {
                  $row.TIME
              }
          }
          | update STATE {|row| match $row.STATE {
              # Colored state
              "RUNNING" => $"(ansi green)($row.STATE)(ansi reset)"
              "PENDING" => $"(ansi yellow)($row.STATE)(ansi reset)"
              _ => $row.STATE
          }}
          | select JOBID STATE PARTITION NAME TIME WHERE
      );
      if ($jobs | is-empty) { "no jobs queued" } else { $jobs }
    ),
  }
}

def "main qos" [] { help main qos }

def "main qos add" [
  name: string # nombre del qos
  --hours: int
  --tres: string # gres/gpu o cpu
  ] {
    let min = $hours * 60

    sudo sacctmgr add qos ($name) GrpTRESMins=($tres)=($min) Priority=100000 Flags=NoDecay
}

def "main qos ls" [] {
  sacctmgr show qos format=name,priority,GrpTRESMins,flags -P
    | from csv --separator '|'
}

def "main qos show" [name: string] {
  print (scontrol show assoc_mgr flags=qos QOS=($name) | lines) # | select 4 8 | str trim)

  print (
    sacctmgr show assoc format=cluster,account,user,qos,DefaultQOS defaultqos=($name) -P
      | from csv --separator '|'
  )
}

def "main qos update" [
  name: string # qos name
  --priority: int
  ] {
    if $priority != null {
      sudo sacctmgr modify qos ($name) set Priority=($priority)
    } else {
      help main qos update
    }
}

def "main user show" [username: string] {
  sacctmgr show assoc format=cluster,account,user,qos,DefaultQOS users=($username) -P
    | from csv --separator '|'
    | group-by Account
}

def "main user update" [
  users: string
  --reset-qos
  --add-qos: string
  --remove-qos: string
  --default-qos: string
  --cluster: string
  ] {
    if (
      not $reset_qos
      and ($add_qos | is-empty)
      and ($remove_qos | is-empty)
      and ($default_qos | is-empty)
    ) {
      help main user update | print
      exit 1
    }

    for u in ($users | split row ",") {

      mut cmd = ['sacctmgr', 'modify', 'user', $u]

      if $cluster != null {
        $cmd ++= [$"cluster=($cluster)"]
      }

      $cmd ++= ["set"]

      if $add_qos != null {
        $cmd ++= [$"qos+=($add_qos)"]
      }

      if $remove_qos != null {
        $cmd ++= [$"qos-=($remove_qos)"]
      }

      if $default_qos != null {
        $cmd ++= [$"DefaultQOS=($default_qos)"]
      }

      if $reset_qos {
        $cmd ++= ["qos=normal" "DefaultQOS=-1"]
      }

      ^"sudo" ...$cmd
    }
}
