// Umbrella for the libvpx surface vpx-swift uses (see Scripts/build-libvpx.sh).
#include <vpx/vpx_codec.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_encoder.h>
#include <vpx/vpx_image.h>
#include <vpx/vp8dx.h>
#include <vpx/vp8cx.h>

// `vpx_codec_dec_init` is a function-like macro (VPX_DECODER_ABI_VERSION is itself nested).
static inline vpx_codec_err_t vpxs_dec_init(vpx_codec_ctx_t *ctx,
                                            vpx_codec_iface_t *iface,
                                            const vpx_codec_dec_cfg_t *cfg,
                                            vpx_codec_flags_t flags) {
    return vpx_codec_dec_init(ctx, iface, cfg, flags);
}

// Likewise `vpx_codec_enc_init` (VPX_ENCODER_ABI_VERSION composes three nested macros).
static inline vpx_codec_err_t vpxs_enc_init(vpx_codec_ctx_t *ctx,
                                            vpx_codec_iface_t *iface,
                                            const vpx_codec_enc_cfg_t *cfg,
                                            vpx_codec_flags_t flags) {
    return vpx_codec_enc_init(ctx, iface, cfg, flags);
}

// `vpx_codec_control` is a macro that dispatches to a per-ID typed wrapper, and the underlying
// `vpx_codec_control_` is C-variadic — Swift can call neither. Every control VpxSwift sets takes a
// single int-compatible argument, so one shim covers them all.
static inline vpx_codec_err_t vpxs_control_int(vpx_codec_ctx_t *ctx, int ctrl_id, int value) {
    return vpx_codec_control_(ctx, ctrl_id, value);
}
