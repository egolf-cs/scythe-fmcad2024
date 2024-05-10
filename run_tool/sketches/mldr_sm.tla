---- MODULE mldr_sm ----
\*
\* Logless protocol for managing configuration state for dynamic reconfiguration
\* in MongoDB replication.
\*

EXTENDS Naturals, Integers, FiniteSets, Sequences, TLC

CONSTANTS MaxTerm, MaxConfigVersion
CONSTANTS Server
CONSTANTS Secondary, Primary

Term == 0..MaxTerm
Version == 1..MaxConfigVersion

VARIABLE currentTerm
VARIABLE state
VARIABLE configVersion
VARIABLE configTerm
VARIABLE config

vars == <<currentTerm, state, configVersion, configTerm, config>>

\*
\* Helper operators.
\*

\* The set of all majority quorums of a given set.
Quorums(S) == {i \in SUBSET(S) : Cardinality(i) * 2 > Cardinality(S)}

\* Do all quorums of two sets intersect.
QuorumsOverlap(x, y) == \A qx \in Quorums(x), qy \in Quorums(y) : qx \cap qy # {}

\* The min/max of a set of numbers.
Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y

\* Is a sequence empty.
Empty(s) == Len(s) = 0

\* Is the config of node i considered 'newer' than the config of node j. This is the condition for
\* node j to accept the config of node i.
IsNewerConfig(i, j) ==
    \/ configTerm[i] > configTerm[j]
    \/ /\ configTerm[i] = configTerm[j]
       /\ configVersion[i] > configVersion[j]

IsNewerOrEqualConfig(i, j) ==
    \/ /\ configTerm[i] = configTerm[j]
       /\ configVersion[i] = configVersion[j]
    \/ IsNewerConfig(i, j)

\* Compares two configs given as <<configVersion, configTerm>> tuples.
NewerConfig(ci, cj) ==
    \* Compare configTerm first.
    \/ ci[2] > cj[2] 
    \* Compare configVersion if terms are equal.
    \/ /\ ci[2] = cj[2]
       /\ ci[1] > cj[1]  

\* Compares two configs given as <<configVersion, configTerm>> tuples.
NewerOrEqualConfig(ci, cj) == NewerConfig(ci, cj) \/ ci = cj

\* Can node 'i' currently cast a vote for node 'j' in term 'term'.
CanVoteForConfig(i, j, term) ==
    /\ currentTerm[i] < term
    /\ IsNewerOrEqualConfig(j, i)
    
\* A quorum of servers in the config of server i have i's config.
ConfigQuorumCheck(i) ==
    \E Q \in Quorums(config[i]) : \A t \in Q : 
        /\ configVersion[t] = configVersion[i]
        /\ configTerm[t] = configTerm[i]

\* A quorum of servers in the config of server i have the term of i.
TermQuorumCheck(i) ==
    \E Q \in Quorums(config[i]) : \A t \in Q : currentTerm[t] = currentTerm[i]    

SymmDiff(X, Y) == (X \ Y) \cup (Y \ X)

-------------------------------------------------------------------------------------------

\*
\* Next state actions.
\*

\* Update terms if node 'i' has a newer term than node 'j' and ensure 'j' reverts to Secondary state.
UpdateTermsExpr(i, j, newTerm) ==
    /\ currentTerm[i] > currentTerm[j]
    /\ newTerm = currentTerm[i]
    /\ currentTerm' = [currentTerm EXCEPT ![j] = newTerm]
    /\ state' = [state EXCEPT ![j] = Secondary]

UpdateTerms(i, j, newTerm) == 
    /\ UpdateTermsExpr(i, j, newTerm)
    /\ UNCHANGED <<configVersion, configTerm, config>>

BecomeLeader(i, voteQuorum, newTerm) == 
    \* Primaries make decisions based on their current configuration.
    /\ newTerm = currentTerm[i] + 1
    /\ voteQuorum \in Quorums(config[i])
    /\ i \in config[i]
    /\ i \in voteQuorum
    /\ \A v \in voteQuorum : CanVoteForConfig(v, i, newTerm)
    \* Update the terms of each voter.
    /\ currentTerm' = [s \in Server |-> IF s \in voteQuorum THEN newTerm ELSE currentTerm[s]]
    /\ state' = [s \in Server |->
                    IF s = i THEN Primary
                    ELSE IF s \in voteQuorum THEN Secondary \* All voters should revert to secondary state.
                    ELSE state[s]]
    \* Update config's term on step-up.
    /\ configTerm' = [configTerm EXCEPT ![i] = newTerm]
    /\ UNCHANGED <<config, configVersion>>    

\* <actions>

\* A reconfig occurs on node i. The node must currently be a leader.
Reconfig(i, newConfig, newVersion) ==
    /\ state[i] = Primary
    /\ ConfigQuorumCheck(i)
    /\ TermQuorumCheck(i)
    \* /\ QuorumsOverlap(config[i], newConfig)
    /\ Cardinality(SymmDiff(config[i], newConfig)) <= 1
    /\ i \in newConfig
    /\ newConfig # config[i]
    /\ configTerm' = [configTerm EXCEPT ![i] = currentTerm[i]]
    \* /\ newVersion = configVersion[i] + 1
    /\ newVersion > configVersion[i]
    /\ configVersion' = [configVersion EXCEPT ![i] = newVersion]
    /\ config' = [config EXCEPT ![i] = newConfig]
    /\ currentTerm' = currentTerm
    /\ state' = state

\* </actions>

\* Node i sends its current config to node j.
SendConfig(i, j, newTerm, newVersion) ==
    /\ state[j] = Secondary
    /\ IsNewerConfig(i, j)
    /\ newTerm = configTerm[i]
    /\ configTerm' = [configTerm EXCEPT ![j] = newTerm]
    /\ newVersion = configVersion[i]
    /\ configVersion' = [configVersion EXCEPT ![j] = newVersion]
    /\ config' = [config EXCEPT ![j] = config[i]]
    /\ UNCHANGED <<currentTerm, state>>

termination == 
    \A s \in Server : 
        /\ configTerm[s] = MaxTerm
        /\ currentTerm[s] = MaxTerm
        /\ configVersion[s] = MaxConfigVersion

Termination == 
    /\ termination
    /\ UNCHANGED vars

Init == 
    /\ currentTerm = [i \in Server |-> 0]
    /\ state       = [i \in Server |-> Secondary]
    /\ configVersion =  [i \in Server |-> 1]
    /\ configTerm    =  [i \in Server |-> 0]
    /\ \E initConfig \in SUBSET Server :
        /\ initConfig # {}
        /\ config = [i \in Server |-> initConfig]

Next == 
    \/ (\E s \in Server : \E Q \in SUBSET Server : \E newTerm \in Term :
        BecomeLeader(s, Q, newTerm))
    \/ (\E s,t \in Server : \E newTerm \in Term : 
        UpdateTerms(s, t, newTerm))
    \/ (\E s \in Server, newConfig \in SUBSET Server : 
        \E newVersion \in Version:
        Reconfig(s, newConfig, newVersion))
    \/ (\E s,t \in Server :  
        \E newTerm \in Term, newVersion \in Version: 
        SendConfig(s, t, newTerm, newVersion))
    \/ Termination

OnePrimaryPerTerm == 
    \A s,t \in Server :
        (/\ state[s] = Primary 
         /\ state[t] = Primary
         /\ currentTerm[s] = currentTerm[t]) => (s = t)


\* <properties>
Safety ==
    /\ OnePrimaryPerTerm
    /\ \A s \in Server : state[s] = Primary => configTerm[s] = currentTerm[s]

Temporal == [][
    \A s \in Server : 
        state[s] = Primary /\ configVersion[s] # configVersion'[s] 
        => config[s] # config'[s]
    ]_vars

Liveness == 
    /\ <> termination
\* </properties>

Spec == 
    /\ Init 
    /\ [][Next]_vars
    /\ WF_vars(Next)

\* StateConstraint == \A s \in Server :
                    \* /\ currentTerm[s] <= MaxTerm
                    \* /\ configVersion[s] <= MaxConfigVersion

ServerSymmetry == Permutations(Server)

=============================================================================