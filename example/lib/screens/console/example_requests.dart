/// Ready-made requests, every one of them aimed at a route the in-process demo
/// server actually serves.
///
/// They exist so the console's empty state can teach instead of apologise: a new
/// reader presses one, sees a real response, and now knows what the fields do.
/// Keep this list honest — a preset pointing at a route that 404s teaches the
/// wrong lesson about whichever library happens to be selected.
library;

import 'package:flutter/foundation.dart';

import '../../core/request_spec.dart';

/// One labelled starting point.
@immutable
final class ExampleRequest {
  /// Creates a preset.
  const ExampleRequest({
    required this.label,
    required this.blurb,
    required this.spec,
    this.quick = false,
  });

  /// Menu title.
  final String label;

  /// One line on what it demonstrates.
  final String blurb;

  /// The request loaded into the draft.
  final RequestSpec spec;

  /// Whether this one is offered in the empty response pane as a one-tap start.
  final bool quick;
}

/// The presets, in the order they are offered.
const List<ExampleRequest> exampleRequests = <ExampleRequest>[
  ExampleRequest(
    label: 'GET /echo',
    blurb: 'Echoes the method, path, query and headers back as JSON.',
    quick: true,
    spec: RequestSpec(
      url: '/echo',
      query: <KeyValueRow>[
        KeyValueRow(name: 'q', value: 'nitro'),
        KeyValueRow(name: 'page', value: '2'),
      ],
      headers: <KeyValueRow>[
        KeyValueRow(name: 'X-Demo', value: 'console'),
        KeyValueRow(name: 'Accept', value: 'application/json'),
      ],
    ),
  ),
  ExampleRequest(
    label: 'POST /echo — JSON body',
    blurb: 'Round-trips a JSON payload so you can see it arrive intact.',
    quick: true,
    spec: RequestSpec(
      method: 'POST',
      url: '/echo',
      bodyKind: RequestBodyKind.json,
      bodyText: '{\n  "name": "nitro_http",\n  "native": true,\n  "runs": 3\n}',
    ),
  ),
  ExampleRequest(
    label: 'GET /bytes/1048576',
    blurb: 'One mebibyte of body, the shape of a throughput test.',
    quick: true,
    spec: RequestSpec(url: '/bytes/1048576'),
  ),
  ExampleRequest(
    label: 'GET /drip/32/25 — streamed',
    blurb: 'Thirty-two chunks, 25 ms apart, consumed as a stream.',
    spec: RequestSpec(
      url: '/drip/32/25',
      responseMode: ResponseMode.streamed,
    ),
  ),
  ExampleRequest(
    label: 'POST /upload — multipart',
    blurb: 'A text part and a field part; the server reports what it received.',
    spec: RequestSpec(
      method: 'POST',
      url: '/upload',
      bodyKind: RequestBodyKind.multipart,
      parts: <MultipartPart>[
        MultipartPart(field: 'title', value: 'console upload'),
        MultipartPart(
          field: 'notes',
          value: 'sent from the request console',
          contentType: 'text/plain',
        ),
      ],
    ),
  ),
  ExampleRequest(
    label: 'GET /redirect/3',
    blurb: 'Three hops to /echo — watch the redirect count and final URL.',
    spec: RequestSpec(url: '/redirect/3'),
  ),
  ExampleRequest(
    label: 'GET /status/404',
    blurb: 'A failing status is a response, not an error. It should look like one.',
    quick: true,
    spec: RequestSpec(url: '/status/404'),
  ),
  ExampleRequest(
    label: 'GET /gzip',
    blurb: 'Compressed on the wire; turn Accept-Encoding off to see the raw form.',
    spec: RequestSpec(url: '/gzip'),
  ),
  ExampleRequest(
    label: 'GET /slow/1500 — 400 ms timeout',
    blurb: 'Deliberately times out, so you can compare what each client says.',
    spec: RequestSpec(
      url: '/slow/1500',
      totalTimeout: Duration(milliseconds: 400),
    ),
  ),
  ExampleRequest(
    label: 'GET /cache/60',
    blurb: 'Cacheable for a minute — only nitro_http has a disk cache to use it.',
    spec: RequestSpec(url: '/cache/60'),
  ),
  ExampleRequest(
    label: 'GET /setcookie',
    blurb: 'Sets a cookie; follow it with /readcookie to see the jar work.',
    spec: RequestSpec(url: '/setcookie'),
  ),
];
