#pragma once

// All calls are serialized by the owning transport lock. No IOKit dependency.
class MMIOTransaction {
public:
    using Word = unsigned long long;
    enum class State { idle, queued, fetched, replied, cancelled };
    enum class Op : Word { read32 = 0, write32 = 1 };
    struct Request {
        Word sequence, operation, offset, value;
    };

    bool begin(Op op, Word offset, Word value) {
        if (state_ != State::idle || offset >= 0x4000 || offset % 4 ||
            value > 0xffffffffULL || next_ == 0 ||
            (op != Op::read32 && op != Op::write32) || (op == Op::read32 && value))
            return false;
        request_ = {next_++, static_cast<Word>(op), offset, value};
        state_ = State::queued;
        return true;
    }
    bool fetch(Request &result) {
        if (state_ != State::queued)
            return false;
        result = request_;
        state_ = State::fetched;
        return true;
    }
    bool reply(Word sequence, Word status, Word value) {
        if (state_ != State::fetched || sequence != request_.sequence ||
            status > 1 || value > 0xffffffffULL ||
            ((status || request_.operation == static_cast<Word>(Op::write32)) && value))
            return false;
        status_ = status;
        value_ = value;
        state_ = State::replied;
        return true;
    }
    void cancel() {
        if (state_ != State::idle)
            state_ = State::cancelled;
    }
    State state() const { return state_; }
    bool waiting() const { return state_ == State::queued || state_ == State::fetched; }
    bool consume(Word &value) {
        const bool ok = state_ == State::replied && status_ == 0;
        if (ok)
            value = value_;
        state_ = State::idle;
        return ok;
    }

private:
    State state_ = State::idle;
    Word next_ = 1;
    Request request_{};
    Word status_ = 0, value_ = 0;
};
