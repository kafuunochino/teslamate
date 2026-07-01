# Third-party notices

## TeslaMate Chinese dashboards

Twenty-five read-only dashboard files are derived from
[`wjsall/teslamate-chinese-dashboards`](https://github.com/wjsall/teslamate-chinese-dashboards)
at commit `d8137ebce69cb7e00e956ef94e9f47fc73039dc0`.

The source project states that these dashboard works are licensed under the
GNU Affero General Public License version 3 or later. They have been modified
for this repository to remove database writes, third-party panel dependencies,
automatic remote media loading, unsafe TOU controls, and map providers that are
unsuitable for the mainland-China default configuration. TOU calculations were
reimplemented as namespaced side-table functions that never overwrite TeslaMate's
native charging cost.

The WGS-84 to GCJ-02 mathematics is based on the implementation documented by
the source project as derived from the `eviltransform` algorithm. This copy is
namespaced, reviewed, and covered by this repository's AGPL-3.0 license.
