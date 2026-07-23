#!/bin/sh
# aichat.model.glossary.library.sh
# Turns a model name / GGUF filename into a short "Name decoder" — one terse line per
# acronym (size, quantization, Instruct/Chat, context, MoE, reasoning, …). The full
# explanations live in the Model Guide help window (the ? button); these lines are
# just quick reminders. Output is markdown in ONE paragraph (bold label + two-space
# hard break — blank lines must be avoided, the SwiftUI .full renderer drops them).
# Two entry points, sourced by the "Model Info" handlers:
#   decode_model_acronyms  — whole name; used by both windows' info panes
#   decode_quant_acronyms  — quant + Unsloth-UD only; used by the HF quant table
[ -n "${__AICHAT_GLOSSARY_LIB:-}" ] && return 0
__AICHAT_GLOSSARY_LIB=1
source "$OMC_APP_BUNDLE_PATH/Contents/Resources/Scripts/aichat.library.sh"

# __GLO_BR is the two-space markdown hard line break (same trick the info panes use
# for their key/value lines). Kept in a var so the trailing spaces survive editing.
__GLO_BR="  "

# _glo <text> — append one decoded entry (one line) to the global $out.
_glo() {
    out="${out}${1}${__GLO_BR}
"
}

# _emit_quant <name> — append the quantization + Unsloth-Dynamic line for the quant
# token found in <name> (Q4_K_M, Q6_K, IQ4_XS, UD-Q4_K_XL, F16/BF16/F32, …).
_emit_quant() {
    _q_base="$1"
    _q_lower=$(printf '%s' "$_q_base" | /usr/bin/tr 'A-Z' 'a-z')

    _q=$(printf '%s' "$_q_base" | /usr/bin/grep -oiE 'mxfp4(_moe)?|nvfp4|iq[0-9](_(xxs|xs|nl|s|m|xl))?|q[0-9](_k(_(s|m|l|xl))?|_[0-9])?|bf16|fp16|f16|f32' | /usr/bin/head -1)
    if [ -n "$_q" ]; then
        _qup=$(printf '%s' "$_q" | /usr/bin/tr 'a-z' 'A-Z')
        case "$_qup" in
            F32)
                _glo "**F32** — 32-bit · maximum quality, very large" ;;
            F16|FP16|BF16)
                _glo "**${_qup}** — 16-bit · full quality, large & slow" ;;
            MXFP4|MXFP4_MOE|NVFP4)
                _glo "**${_qup%_MOE}** — 4-bit float (microscaling) · compact & efficient" ;;
            *)
                _q_bits=$(printf '%s' "$_qup" | /usr/bin/grep -oE '[0-9]+' | /usr/bin/head -1)
                _q_parts="${_q_bits}-bit"
                case "$_qup" in
                    IQ*) _q_parts="${_q_parts} · i-quant" ;;
                    *K*) _q_parts="${_q_parts} · k-quant" ;;
                esac
                case "$_qup" in
                    *_XL) _q_parts="${_q_parts} · XL" ;;
                    *_L)  _q_parts="${_q_parts} · large" ;;
                    *_M)  _q_parts="${_q_parts} · medium" ;;
                    *_S|*XS|*XXS) _q_parts="${_q_parts} · small" ;;
                esac
                case "$_qup" in
                    Q8_0) : ;;
                    Q[0-9]_[0-9]) _q_parts="${_q_parts} · legacy" ;;
                esac
                case "$_q_bits" in
                    8) _q_parts="${_q_parts} · near-lossless" ;;
                    6) _q_parts="${_q_parts} · near-full quality" ;;
                    5) _q_parts="${_q_parts} · high quality" ;;
                    4) _q_parts="${_q_parts} · recommended" ;;
                    3) _q_parts="${_q_parts} · lower quality" ;;
                    2) _q_parts="${_q_parts} · low quality" ;;
                    1) _q_parts="${_q_parts} · minimal quality" ;;
                esac
                _glo "**${_qup}** — ${_q_parts}"
                ;;
        esac
    fi

    # Unsloth Dynamic quants: ...-UD-Q4_K_XL, UD-IQ2_M, … (UD sits right before the quant).
    case "$_q_lower" in
        *-ud-q[0-9]*|*-ud-iq[0-9]*|ud-q[0-9]*|ud-iq[0-9]*)
            _glo "**UD** — Unsloth Dynamic quant · better quality for its size" ;;
    esac
}

# decode_model_acronyms <model-name-or-filename>
# Prints a markdown "Name decoder" section, or nothing if no acronyms are recognised.
decode_model_acronyms() {
    _dma_name="$1"
    [ -z "$_dma_name" ] && return 0

    _dma_base="${_dma_name%.gguf}"
    _dma_base="${_dma_base%.GGUF}"
    _dma_lower=$(printf '%s' "$_dma_base" | /usr/bin/tr 'A-Z' 'a-z')

    out=""

    # ── Effective parameters (Gemma 3n): E2B, E4B ───────────────────────────
    # 'E' = effective size (runs at a smaller footprint than its raw params via
    # Per-Layer Embeddings / MatFormer). Detected before the plain size below so the
    # 'NB' grep doesn't mislabel the E-number as a raw parameter count.
    _dma_eff=$(printf '%s' "$_dma_base" | /usr/bin/grep -oiE '(^|[-_.])e[0-9]+b' | /usr/bin/grep -oiE 'e[0-9]+b' | /usr/bin/head -1)
    if [ -n "$_dma_eff" ]; then
        _dma_eff_up=$(printf '%s' "$_dma_eff" | /usr/bin/tr 'a-z' 'A-Z')
        _glo "**${_dma_eff_up}** — effective parameters · runs light for its true size"
    else
        # ── Parameter count: 7B, 8B, 70B, 1.5B, 405B … ──────────────────────
        _dma_size=$(printf '%s' "$_dma_base" | /usr/bin/grep -oiE '[0-9]+(\.[0-9]+)?b' | /usr/bin/head -1)
        if [ -n "$_dma_size" ]; then
            _dma_size_up=$(printf '%s' "$_dma_size" | /usr/bin/tr 'a-z' 'A-Z')
            _glo "**${_dma_size_up}** — parameters · bigger = smarter, slower, heavier"
        else
            # Very small models are sized in millions (135M, 270M). Treat a number ≥ 50
            # followed by 'm' as a parameter count; smaller values are a context length.
            _dma_mil=$(printf '%s' "$_dma_lower" | /usr/bin/grep -oE '[0-9]+m' | /usr/bin/head -1)
            _dma_mnum="${_dma_mil%m}"
            if [ -n "$_dma_mnum" ] && [ "$_dma_mnum" -ge 50 ] 2>/dev/null; then
                _glo "**${_dma_mnum}M** — million parameters · tiny & fast, limited ability"
            fi
        fi
    fi

    # ── Mixture-of-Experts: MoE, 8x7B, A3B (active-billions suffix) ──────────
    case "$_dma_lower" in
        *moe*|*[0-9]x[0-9]*b*|*-a[0-9]*b*|*_a[0-9]*b*)
            _dma_active=$(printf '%s' "$_dma_base" | /usr/bin/grep -oiE 'a[0-9]+(\.[0-9]+)?b' | /usr/bin/head -1)
            if [ -n "$_dma_active" ]; then
                _dma_act_disp=$(printf '%s' "$_dma_active" | /usr/bin/tr 'a-z' 'A-Z')
                _glo "**MoE / ${_dma_act_disp}** — only part runs per token · fast, but loads fully"
            else
                _glo "**MoE** — few experts per token · fast for its size, loads fully"
            fi
            ;;
    esac

    # ── Quantization + Unsloth Dynamic ──────────────────────────────────────
    _emit_quant "$_dma_base"

    # ── Instruction / chat tuning vs. raw base model ────────────────────────
    case "$_dma_lower" in
        *instruct*|*-it-*|*-it|*_it_*|*_it|*-chat*|*chat-*|*-sft*)
            _glo "**Instruct / Chat** — follows instructions & tools · use for chat/agents" ;;
        *-base|*-base-*|*_base|*-pt|*-pt-*)
            _glo "**base / pt** — text completion only · not for chat/tools" ;;
    esac

    # ── Context window: 4k, 32k, 128k … (lower-case 'k' is reliably context) ─
    _dma_ctx=$(printf '%s' "$_dma_lower" | /usr/bin/grep -oE '[0-9]+k' | /usr/bin/head -1)
    if [ -n "$_dma_ctx" ]; then
        _glo "**${_dma_ctx}** — context window · longer input, more memory"
    fi

    # ── Distillation ────────────────────────────────────────────────────────
    case "$_dma_lower" in
        *distill*)
            _glo "**Distill** — mimics a bigger model · small & fast" ;;
    esac

    # ── Reasoning / chain-of-thought models ─────────────────────────────────
    case "$_dma_lower" in
        *-r1*|*deepseek-r1*|*qwq*|*thinking*|*reason*)
            _glo "**Reasoning (R1 / QwQ)** — thinks before answering · smarter, slower" ;;
    esac

    # ── Vision / multimodal ─────────────────────────────────────────────────
    case "$_dma_lower" in
        *-vl*|*vision*|*llava*)
            _glo "**VL / Vision** — also reads images · needs projector + memory" ;;
    esac

    # ── Domain specialists: code / math ─────────────────────────────────────
    case "$_dma_lower" in
        *coder*|*-code*|*codestral*|*math*)
            _glo "**Coder / Math** — specialised for code/maths" ;;
    esac

    # ── Vendor size tier (label, not a parameter count) ─────────────────────
    case "$_dma_lower" in
        *mini*|*-small*|*-medium*|*-large*|*nano*|*tiny*|*micro*)
            _dma_tier=$(printf '%s' "$_dma_lower" | /usr/bin/grep -oiE 'mini|small|medium|large|nano|tiny|micro' | /usr/bin/head -1)
            _glo "**${_dma_tier}** — vendor size tier · check the nB number" ;;
    esac

    # ── Safety-stripped variants ────────────────────────────────────────────
    case "$_dma_lower" in
        *abliterat*|*uncensored*|*-dolphin*|*dolphin-*)
            _glo "**Uncensored** — fewer refusals · less predictable" ;;
    esac

    # ── Version tag: v0.2, v1.6, v2 … ───────────────────────────────────────
    _dma_ver=$(printf '%s' "$_dma_lower" | /usr/bin/grep -oiE 'v[0-9]+(\.[0-9]+)*' | /usr/bin/head -1)
    if [ -n "$_dma_ver" ]; then
        _glo "**${_dma_ver}** — version · higher = newer"
    fi

    # Nothing recognised → emit nothing so the caller can skip the section.
    [ -z "$out" ] && return 0

    printf '%s' "**Name decoder**${__GLO_BR}
${out}"
}

# decode_quant_acronyms <quant-filename>
# Prints just the quantization + Unsloth-Dynamic line for a chosen quant file, or
# nothing if no quant token is found. Used by the HF quant-table selection.
decode_quant_acronyms() {
    [ -z "$1" ] && return 0
    out=""
    _dq_base="${1%.gguf}"
    _dq_base="${_dq_base%.GGUF}"
    _emit_quant "$_dq_base"
    [ -z "$out" ] && return 0
    printf '%s' "$out"
}
