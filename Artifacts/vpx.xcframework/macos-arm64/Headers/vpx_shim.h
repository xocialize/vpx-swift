// Umbrella for the VP9/VP8 decode surface of libvpx (see Scripts/build-libvpx.sh).
#include <vpx/vpx_codec.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_image.h>
#include <vpx/vp8dx.h>

// `vpx_codec_dec_init` is a function-like C macro (and VPX_DECODER_ABI_VERSION a nested macro), so it
// is invisible to Swift. This static-inline wrapper — which Swift DOES import — pins the ABI version
// at the exact value this header set was built against, avoiding any hardcoded constant on the Swift side.
static inline vpx_codec_err_t vpxs_dec_init(vpx_codec_ctx_t *ctx,
                                            vpx_codec_iface_t *iface,
                                            const vpx_codec_dec_cfg_t *cfg,
                                            vpx_codec_flags_t flags) {
    return vpx_codec_dec_init(ctx, iface, cfg, flags);
}
