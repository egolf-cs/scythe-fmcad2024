----------------------------- MODULE MongoRaftReconfig -----------------------------

\*
\* MongoDB replication protocol that allows for logless, dynamic reconfiguration.
\*

EXTENDS Naturals, Integers, FiniteSets, Sequences, TLC, Defs

CONSTANTS Server
CONSTANTS Secondary, Primary, Nil

VARIABLE log
VARIABLE committed
VARIABLE currentTerm
VARIABLE state
VARIABLE config
VARIABLE configVersion
VARIABLE configTerm

vars == <<currentTerm, state, log, configVersion, configTerm, config, log, committed>>

\*
\* Helper operators.
\*

GetTerm(xlog, index) == IF index = 0 THEN 0 ELSE xlog[index]
LogTerm(i, index) == GetTerm(log[i], index)

\* Is log entry e = <<index, term>> in the log of node 'i'.
InLog(e, i) == \E x \in DOMAIN log[i] : x = e[1] /\ log[i][x] = e[2]

-------------------------------------------------------------------------------------------


osmVars == <<log, committed>>
csmVars == <<configVersion, configTerm, config>>

\* The config state machine.
CSM == INSTANCE MongoLoglessDynamicRaft 
        WITH currentTerm <- currentTerm,
             state <- state,
             configVersion <- configVersion,
             configTerm <- configTerm,
             config <- config

\* The oplog state machine.
OSM == INSTANCE MongoStaticRaft 
        WITH currentTerm <- currentTerm,
             state <- state,
             log <- log,
             config <- config,
             committed <- committed
             
\*
\* This protocol is specified as a composition of a Config State Machine (which
\* runs MongoLoglessDynamicRaft) and an Oplog State Machine (which runs
\* MongoStaticRaft). The composition is asynchronous except for the election
\* action i.e. both protocols need to execute their election action
\* simultaneously.
\*
Init == 
    /\ CSM!Init 
    /\ OSM!Init

\* Oplog State Machine actions.
OSMNext == 
    \/ \E s \in Server : OSM!ClientRequest(s)
    \/ \E s, t \in Server : OSM!GetEntries(s, t)
    \/ \E s, t \in Server : OSM!RollbackEntries(s, t)
    \/ \E s \in Server :  \E Q \in Quorums(config[s]) : OSM!CommitEntry(s, Q)

\* Check whether the entry at "index" on "primary" is committed in the primary's current config.
IsCommitted(index, primary) ==
    \* The primary must contain such an entry.
    /\ Len(log[primary]) >= index
    \* The entry was written by this leader.
    /\ LogTerm(primary, index) = currentTerm[primary]
    /\ \E quorum \in Quorums(config[primary]):
        \* all nodes have this log entry and are in the term of the leader.
        \A s \in quorum : \E k \in DOMAIN log[s] :
            /\ k = index
            /\ log[s][k] = log[primary][k]    \* they have the entry.
            /\ currentTerm[s] = currentTerm[primary]  \* they are in the same term.

\*
\* This is the precondition about committed oplog entries that must be satisfied
\* on a primary server s in order for it to execute a reconfiguration.
\*
\* When a primary is first elected in term T, we can be sure that it contains
\* all committed entries from terms < T. During its reign as primary in term T
\* though, it needs to make sure that any entries it commits in its own term are
\* correctly transferred to new configurations. That is, before leaving a
\* configuration C, it must make sure that any entry it committed in T is now
\* committed by the rules of configuration C i.e. it is "immediately committed"
\* in C. That is, present on some quorum of servers in C that are in term T. 
OplogCommitment(s) == 
    \* The primary has committed at least one entry in its term, or, no entries
    \* have been committed yet.
    /\ (committed = {}) \/ (\E c \in committed : (c.term = currentTerm[s]))
    \* All entries committed in the primary's term are committed in its current config.
    /\ \A c \in committed : (c.term = currentTerm[s]) => IsCommitted(c.entry[1], s)

\* Config State Machine actions.
CSMNext == 
    \/ \E s \in Server, newConfig \in SUBSET Server : 
        \* Before reconfiguration, ensure that previously committed ops are safe.
        /\ OplogCommitment(s)
        /\ CSM!Reconfig(s, newConfig)
    \/ \E s,t \in Server : CSM!SendConfig(s, t)

\* Actions shared by the CSM and OSM i.e. that must be executed jointly by both protocols.
JointNext == 
    \/ \E i \in Server : \E Q \in Quorums(config[i]) : 
        /\ OSM!BecomeLeader(i, Q)
        /\ CSM!BecomeLeader(i, Q)
    \/ \E s,t \in Server : OSM!UpdateTerms(s,t) /\ CSM!UpdateTerms(s,t)

\* We define the transition relation as an interleaving composition of the OSM and CSM.
\* From the current state, we permit either the OSM or CSM to take a single,
\* non election step. Election steps (i.e. BecomeLeader) actions in either
\* state machine must synchronize i.e. they must be executed simultaneously
\* in both sub protocols.
Next == 
    \/ OSMNext /\ UNCHANGED csmVars
    \/ CSMNext /\ UNCHANGED osmVars
    \/ JointNext

Spec == Init /\ [][Next]_vars

\* Statement of type correctness.
TypeOK ==
    /\ currentTerm \in [Server -> Nat]
    /\ state \in [Server -> {Secondary, Primary}]
    /\ log \in [Server -> Seq(Nat)]
    /\ config \in [Server -> SUBSET Server]
    /\ configVersion \in [Server -> Nat]
    /\ configTerm \in [Server -> Nat]
    /\ committed \in SUBSET [ entry : Nat \X Nat, term : Nat ]

-----------------------------------------------------------------------------

\*
\* Safety properties.
\*

\* There can be at most one primary per term.
OnePrimaryPerTerm == 
    \A s,t \in Server :
        (/\ state[s] = Primary 
         /\ state[t] = Primary
         /\ currentTerm[s] = currentTerm[t]) => (s = t)

\* When a node gets elected as primary it contains all entries committed in previous terms.
LeaderCompleteness == 
    \A s \in Server : (state[s] = Primary) => 
        \A c \in committed : (c.term <= currentTerm[s] => InLog(c.entry, s))

\* If two entries are committed at the same index, they must be the same entry.
StateMachineSafety == 
    \A c1, c2 \in committed : (c1.entry[1] = c2.entry[1]) => (c1 = c2)

=============================================================================
