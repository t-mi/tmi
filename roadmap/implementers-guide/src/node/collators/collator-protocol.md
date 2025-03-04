# Collator Protocol

The Collator Protocol implements the network protocol by which collators and validators communicate. It is used by collators to distribute collations to validators and used by validators to accept collations by collators.

Collator-to-Validator networking is more difficult than Validator-to-Validator networking because the set of possible collators for any given para is unbounded, unlike the validator set. Validator-to-Validator networking protocols can easily be implemented as gossip because the data can be bounded, and validators can authenticate each other by their `PeerId`s for the purposes of instantiating and accepting connections.

Since, at least at the level of the para abstraction, the collator-set for any given para is unbounded, validators need to make sure that they are receiving connections from capable and honest collators and that their bandwidth and time are not being wasted by attackers. Communicating across this trust-boundary is the most difficult part of this subsystem.

Validation of candidates is a heavy task, and furthermore, the [`PoV`][pov] itself is a large piece of data. Empirically, `PoV`s are on the order of 10MB.

> TODO: note the incremental validation function Ximin proposes at https://github.com/tmi/tmi/issues/1348

As this network protocol serves as a bridge between collators and validators, it communicates primarily with one subsystem on behalf of each. As a collator, this will receive messages from the [`CollationGeneration`][cg] subsystem. As a validator, this will communicate with the [`CandidateBacking`][cb] and [`CandidateSelection`][cs] subsystems.

## Protocol

Input: [`CollatorProtocolMessage`][cpm]

Output:

- [`RuntimeApiMessage`][ram]
- [`NetworkBridgeMessage`][nbm]
- [`CandidateSelectionMessage`][csm]

## Functionality

This network protocol uses the `Collation` peer-set of the [`NetworkBridge`][nb].

It uses the [`CollatorProtocolV1Message`](../../types/network.md#collator-protocol) as its `WireMessage`

Since this protocol functions both for validators and collators, it is easiest to go through the protocol actions for each of them separately.

Validators and collators.

```dot process
digraph {
  c1 [shape=MSquare, label="Collator 1"];
  c2 [shape=MSquare, label="Collator 2"];

  v1 [shape=MSquare, label="Validator 1"];
  v2 [shape=MSquare, label="Validator 2"];

  c1 -> v1;
  c1 -> v2;
  c2 -> v2;
}
```

### Collators

It is assumed that collators are only collating on a single parachain. Collations are generated by the [Collation Generation][cg] subsystem. We will keep up to one local collation per relay-parent, based on `DistributeCollation` messages. If the para is not scheduled or next up on any core, at the relay-parent, or the relay-parent isn't in the active-leaves set, we ignore the message as it must be invalid in that case - although this indicates a logic error elsewhere in the node.

We keep track of the Para ID we are collating on as a collator. This starts as `None`, and is updated with each `CollateOn` message received. If the `ParaId` of a collation requested to be distributed does not match the one we expect, we ignore the message.

As with most other subsystems, we track the active leaves set by following `ActiveLeavesUpdate` signals.

For the purposes of actually distributing a collation, we need to be connected to the validators who are interested in collations on that `ParaId` at this point in time. We assume that there is a discovery API for connecting to a set of validators.

> TODO: design & expose the discovery API not just for connecting to such peers but also to determine which of our current peers are validators.

As seen in the [Scheduler Module][sch] of the runtime, validator groups are fixed for an entire session and their rotations across cores are predictable. Collators will want to do these things when attempting to distribute collations at a given relay-parent:

- Determine which core the para collated-on is assigned to.
- Determine the group on that core and the next group on that core.
- Issue a discovery request for the validators of the current group and the next group with[`NetworkBridgeMessage`][nbm]`::ConnectToValidators`.

Once connected to the relevant peers for the current group assigned to the core (transitively, the para), advertise the collation to any of them which advertise the relay-parent in their view (as provided by the [Network Bridge][nb]). If any respond with a request for the full collation, provide it. Upon receiving a view update from any of these peers which includes a relay-parent for which we have a collation that they will find relevant, advertise the collation to them if we haven't already.

### Validators

On the validator side of the protocol, validators need to accept incoming connections from collators. They should keep some peer slots open for accepting new speculative connections from collators and should disconnect from collators who are not relevant.

```dot process
digraph G {
  label = "Declaring, advertising, and providing collations";
  labelloc = "t";
  rankdir = LR;

  subgraph cluster_collator {
      rank = min;
      label = "Collator";
      graph[style = border, rank = min];

      c1, c2 [label = ""];
  }

  subgraph cluster_validator {
      rank = same;
      label = "Validator";
      graph[style = border];

      v1, v2 [label = ""];
  }

  c1 -> v1 [label = "Declare and advertise"];

  v1 -> c2 [label = "Request"];

  c2 -> v2 [label = "Provide"];

  v2 -> v2 [label = "Note Good/Bad"];
}
```

When peers connect to us, they can `Declare` that they represent a collator with given public key. Once they've declared that, they can begin to send advertisements of collations. The peers should not send us any advertisements for collations that are on a relay-parent outside of our view.

The protocol tracks advertisements received and the source of the advertisement. The advertisement source is the `PeerId` of the peer who sent the message. We accept one advertisement per collator per source per relay-parent.

As a validator, we will handle requests from other subsystems to fetch a collation on a specific `ParaId` and relay-parent. These requests are made with the [`CollatorProtocolMessage`][cpm]`::FetchCollation`. To do so, we need to first check if we have already gathered a collation on that `ParaId` and relay-parent. If not, we need to select one of the advertisements and issue a request for it. If we've already issued a request, we shouldn't issue another one until the first has returned.

When acting on an advertisement, we issue a `WireMessage::RequestCollation`. If the request times out, we need to note the collator as being unreliable and reduce its priority relative to other collators. And then make another request - repeat until we get a response or the chain has moved on.

As a validator, once the collation has been fetched some other subsystem will inspect and do deeper validation of the collation. The subsystem will report to this subsystem with a [`CollatorProtocolMessage`][cpm]`::ReportCollator` or `NoteGoodCollation` message. In that case, if we are connected directly to the collator, we apply a cost to the `PeerId` associated with the collator and potentially disconnect or blacklist it.

### Interaction with [Candidate Selection][cs]

As collators advertise the availability, we notify the Candidate Selection subsystem with a [`CandidateSelection`][csm]`::Collation` message. Note that this message is lightweight: it only contains the relay parent, para id, and collator id.

At that point, the Candidate Selection algorithm is free to use an arbitrary algorithm to determine which if any of these messages to follow up on. It is expected to use the [`CollatorProtocolMessage`][cpm]`::FetchCollation` message to follow up.

The intent behind this design is to minimize the total number of (large) collations which must be transmitted.

[cb]: ../backing/candidate-backing.md
[cbm]: ../../types/overseer-protocol.md#candidate-backing-mesage
[cg]: collation-generation.md
[cpm]: ../../types/overseer-protocol.md#collator-protocol-message
[cs]: ../backing/candidate-selection.md
[csm]: ../../types/overseer-protocol.md#candidate-selection-message
[nb]: ../utility/network-bridge.md
[nbm]: ../../types/overseer-protocol.md#network-bridge-message
[pov]: ../../types/availability.md#proofofvalidity
[ram]: ../../types/overseer-protocol.md#runtime-api-message
[sch]: ../../runtime/scheduler.md
