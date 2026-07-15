#include <cstddef>
#include <cstdint>
#include <vector>

enum class BatchStatus
{
    Success,
    BufferTooSmall,
};

struct BatchResult
{
    BatchStatus Status;
    std::size_t BytesWritten;
};

enum class ControlState
{
    Absent,
    Active,
    Deleting,
};

struct PnpReservation
{
    bool Held = false;
};

class AnchorRundownModel final
{
public:
    bool TryAcquireWorker()
    {
        if (cleanupStarted_)
        {
            return false;
        }
        ++outstandingWorkers_;
        return true;
    }

    void BeginCleanup()
    {
        cleanupStarted_ = true;
    }

    void ReleaseWorker()
    {
        if (outstandingWorkers_ != 0)
        {
            --outstandingWorkers_;
        }
    }

    bool CleanupCanReturn() const
    {
        return cleanupStarted_ && outstandingWorkers_ == 0;
    }

    std::size_t OutstandingWorkers() const
    {
        return outstandingWorkers_;
    }

private:
    bool cleanupStarted_ = false;
    std::size_t outstandingWorkers_ = 0;
};

class ControlLifecycleModel final
{
public:
    ControlLifecycleModel(
        ControlState state,
        std::size_t pnpDeviceCount,
        std::uint64_t controlGeneration)
        : state_(state),
          pnpDeviceCount_(pnpDeviceCount),
          controlGeneration_(controlGeneration),
          nextGeneration_(controlGeneration + 1)
    {
    }

    void Acquire(PnpReservation& reservation)
    {
        Acquire(reservation, true);
    }

    void Acquire(PnpReservation& reservation, bool createSucceeds)
    {
        if (reservation.Held)
        {
            return;
        }

        reservation.Held = true;
        ++pnpDeviceCount_;
        if (state_ == ControlState::Absent)
        {
            ++createRequests_;
            if (createSucceeds)
            {
                state_ = ControlState::Active;
                controlGeneration_ = nextGeneration_++;
            }
        }
        else if (state_ == ControlState::Deleting &&
                 controlGeneration_ == 0 &&
                 !recreateQueued_)
        {
            recreateQueued_ = true;
        }
    }

    void Release(PnpReservation& reservation)
    {
        if (!reservation.Held)
        {
            return;
        }

        reservation.Held = false;
        --pnpDeviceCount_;
        if (pnpDeviceCount_ == 0 && state_ == ControlState::Active)
        {
            state_ = ControlState::Deleting;
            ++deleteRequests_;
        }
    }

    void Destroy(std::uint64_t controlGeneration)
    {
        if (state_ == ControlState::Deleting &&
            controlGeneration_ == controlGeneration)
        {
            controlGeneration_ = 0;
            recreateQueued_ = pnpDeviceCount_ != 0;
        }
    }

    void RunRecreateWorker(bool createSucceeds)
    {
        RunRecreateWorkerAfterNameCollisions(0, createSucceeds);
    }

    void RunRecreateWorkerAfterNameCollisions(
        std::size_t collisionCount,
        bool finalCreateSucceeds)
    {
        if (!recreateQueued_)
        {
            return;
        }

        if (state_ == ControlState::Deleting &&
            controlGeneration_ == 0 &&
            pnpDeviceCount_ != 0)
        {
            constexpr std::size_t maximumCollisionRetries = 4;
            for (std::size_t attempt = 0;
                 attempt <= maximumCollisionRetries;
                 ++attempt)
            {
                ++createRequests_;
                ++workerCreateAttempts_;
                if (collisionCount != 0)
                {
                    --collisionCount;
                    if (attempt == maximumCollisionRetries)
                    {
                        state_ = ControlState::Deleting;
                        recreateQueued_ = false;
                        return;
                    }
                    ++workerDelayCount_;
                    continue;
                }

                state_ = finalCreateSucceeds
                    ? ControlState::Active
                    : ControlState::Deleting;
                if (finalCreateSucceeds)
                {
                    controlGeneration_ = nextGeneration_++;
                }
                recreateQueued_ = false;
                return;
            }
        }

        recreateQueued_ = false;
    }

    void RunRecreateWorker()
    {
        RunRecreateWorker(true);
    }

    ControlState State() const
    {
        return state_;
    }

    std::size_t PnpDeviceCount() const
    {
        return pnpDeviceCount_;
    }

    std::uint64_t ControlGeneration() const
    {
        return controlGeneration_;
    }

    std::size_t DeleteRequests() const
    {
        return deleteRequests_;
    }

    std::size_t CreateRequests() const
    {
        return createRequests_;
    }

    bool RecreateQueued() const
    {
        return recreateQueued_;
    }

    std::size_t WorkerCreateAttempts() const
    {
        return workerCreateAttempts_;
    }

    std::size_t WorkerDelayCount() const
    {
        return workerDelayCount_;
    }

private:
    ControlState state_;
    std::size_t pnpDeviceCount_;
    std::uint64_t controlGeneration_;
    std::uint64_t nextGeneration_;
    std::size_t deleteRequests_ = 0;
    std::size_t createRequests_ = 0;
    std::size_t workerCreateAttempts_ = 0;
    std::size_t workerDelayCount_ = 0;
    bool recreateQueued_ = false;
};

class RingModel final
{
public:
    explicit RingModel(std::size_t capacity)
        : slots_(capacity), wireLengths_(capacity)
    {
    }

    bool Push(std::uint64_t sequence)
    {
        return Push(sequence, 1);
    }

    bool Push(std::uint64_t sequence, std::size_t wireLength)
    {
        if (count_ == slots_.size())
        {
            ++dropped_;
            return false;
        }

        slots_[tail_] = sequence;
        wireLengths_[tail_] = wireLength;
        tail_ = (tail_ + 1) % slots_.size();
        ++count_;
        return true;
    }

    BatchResult PopBatch(std::size_t outputLength)
    {
        BatchResult result{BatchStatus::Success, 0};

        while (count_ != 0)
        {
            const std::size_t wireLength = wireLengths_[head_];
            if (wireLength > outputLength - result.BytesWritten)
            {
                if (result.BytesWritten == 0)
                {
                    result.Status = BatchStatus::BufferTooSmall;
                }
                return result;
            }

            result.BytesWritten += wireLength;
            (void)Pop();
        }

        return result;
    }

    std::uint64_t Pop()
    {
        const std::uint64_t sequence = slots_[head_];
        head_ = (head_ + 1) % slots_.size();
        --count_;
        return sequence;
    }

    std::uint64_t At(std::size_t index) const
    {
        return slots_[(head_ + index) % slots_.size()];
    }

    std::size_t Count() const
    {
        return count_;
    }

    std::uint64_t Dropped() const
    {
        return dropped_;
    }

private:
    std::vector<std::uint64_t> slots_;
    std::vector<std::size_t> wireLengths_;
    std::size_t head_ = 0;
    std::size_t tail_ = 0;
    std::size_t count_ = 0;
    std::uint64_t dropped_ = 0;
};

static int Require(bool condition, int line)
{
    return condition ? 0 : line;
}

int main()
{
    RingModel ring(2);

    if (const int result = Require(ring.Push(1), __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(ring.Push(2), __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(!ring.Push(3), __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(ring.Count() == 2, __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(ring.At(0) == 1 && ring.At(1) == 2, __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(ring.Dropped() == 1, __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(ring.Pop() == 1, __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(ring.Push(4), __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(ring.Count() == 2, __LINE__); result != 0)
    {
        return result;
    }
    if (const int result = Require(ring.At(0) == 2 && ring.At(1) == 4, __LINE__); result != 0)
    {
        return result;
    }

    RingModel firstTooLarge(2);
    if (const int result = Require(firstTooLarge.Push(10, 100), __LINE__); result != 0)
    {
        return result;
    }
    const BatchResult tooSmall = firstTooLarge.PopBatch(99);
    if (const int result = Require(
            tooSmall.Status == BatchStatus::BufferTooSmall &&
                tooSmall.BytesWritten == 0 &&
                firstTooLarge.Count() == 1 &&
                firstTooLarge.At(0) == 10,
            __LINE__);
        result != 0)
    {
        return result;
    }

    RingModel partialBatch(2);
    if (const int result = Require(
            partialBatch.Push(20, 100) && partialBatch.Push(21, 80),
            __LINE__);
        result != 0)
    {
        return result;
    }
    const BatchResult partial = partialBatch.PopBatch(150);
    if (const int result = Require(
            partial.Status == BatchStatus::Success &&
                partial.BytesWritten == 100 &&
                partialBatch.Count() == 1 &&
                partialBatch.At(0) == 21,
            __LINE__);
        result != 0)
    {
        return result;
    }

    RingModel empty(2);
    const BatchResult emptyResult = empty.PopBatch(68);
    if (const int result = Require(
            emptyResult.Status == BatchStatus::Success &&
                emptyResult.BytesWritten == 0 &&
                empty.Count() == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }

    PnpReservation originalReservation{true};
    PnpReservation newReservation;
    PnpReservation destroyWindowReservation;
    ControlLifecycleModel lifecycle(ControlState::Active, 1, 1);

    lifecycle.Release(originalReservation);
    if (const int result = Require(
            lifecycle.State() == ControlState::Deleting &&
                lifecycle.PnpDeviceCount() == 0 &&
                lifecycle.ControlGeneration() == 1 &&
                lifecycle.DeleteRequests() == 1,
            __LINE__);
        result != 0)
    {
        return result;
    }

    lifecycle.Acquire(newReservation);
    if (const int result = Require(
            newReservation.Held &&
                lifecycle.State() == ControlState::Deleting &&
                lifecycle.PnpDeviceCount() == 1 &&
                lifecycle.ControlGeneration() == 1 &&
                lifecycle.CreateRequests() == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }

    lifecycle.Destroy(1);
    if (const int result = Require(
            lifecycle.State() == ControlState::Deleting &&
                lifecycle.ControlGeneration() == 0 &&
                lifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    lifecycle.Acquire(destroyWindowReservation);
    if (const int result = Require(
            destroyWindowReservation.Held &&
                lifecycle.State() == ControlState::Deleting &&
                lifecycle.PnpDeviceCount() == 2 &&
                lifecycle.ControlGeneration() == 0 &&
                lifecycle.CreateRequests() == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }

    lifecycle.RunRecreateWorker();
    if (const int result = Require(
            lifecycle.State() == ControlState::Active &&
                lifecycle.PnpDeviceCount() == 2 &&
                lifecycle.ControlGeneration() == 2 &&
                lifecycle.CreateRequests() == 1 &&
                !lifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    lifecycle.Release(originalReservation);
    if (const int result = Require(
            lifecycle.State() == ControlState::Active &&
                lifecycle.PnpDeviceCount() == 2 &&
                lifecycle.ControlGeneration() == 2 &&
                lifecycle.DeleteRequests() == 1,
            __LINE__);
        result != 0)
    {
        return result;
    }

    PnpReservation failedOriginal{true};
    PnpReservation failedReplacement;
    ControlLifecycleModel failedLifecycle(ControlState::Active, 1, 10);
    failedLifecycle.Release(failedOriginal);
    failedLifecycle.Acquire(failedReplacement);
    failedLifecycle.Destroy(10);
    failedLifecycle.RunRecreateWorker(false);
    if (const int result = Require(
            failedLifecycle.State() == ControlState::Deleting &&
                failedLifecycle.PnpDeviceCount() == 1 &&
                failedLifecycle.ControlGeneration() == 0 &&
                failedLifecycle.CreateRequests() == 1 &&
                !failedLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    PnpReservation retryReservation;
    failedLifecycle.Acquire(retryReservation, true);
    if (const int result = Require(
            retryReservation.Held &&
                failedLifecycle.State() == ControlState::Deleting &&
                failedLifecycle.PnpDeviceCount() == 2 &&
                failedLifecycle.ControlGeneration() == 0 &&
                failedLifecycle.CreateRequests() == 1 &&
                failedLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }
    failedLifecycle.RunRecreateWorker();
    if (const int result = Require(
            failedLifecycle.State() == ControlState::Active &&
                failedLifecycle.ControlGeneration() == 11 &&
                failedLifecycle.CreateRequests() == 2 &&
                !failedLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    PnpReservation noAnchorOriginal{true};
    PnpReservation afterDestroyReservation;
    ControlLifecycleModel noAnchorLifecycle(ControlState::Active, 1, 20);
    noAnchorLifecycle.Release(noAnchorOriginal);
    noAnchorLifecycle.Destroy(20);
    if (const int result = Require(
            noAnchorLifecycle.State() == ControlState::Deleting &&
                noAnchorLifecycle.PnpDeviceCount() == 0 &&
                noAnchorLifecycle.ControlGeneration() == 0 &&
                !noAnchorLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    noAnchorLifecycle.Acquire(afterDestroyReservation);
    if (const int result = Require(
            afterDestroyReservation.Held &&
                noAnchorLifecycle.State() == ControlState::Deleting &&
                noAnchorLifecycle.PnpDeviceCount() == 1 &&
                noAnchorLifecycle.ControlGeneration() == 0 &&
                noAnchorLifecycle.RecreateQueued() &&
                noAnchorLifecycle.CreateRequests() == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }

    noAnchorLifecycle.RunRecreateWorker();
    if (const int result = Require(
            noAnchorLifecycle.State() == ControlState::Active &&
                noAnchorLifecycle.ControlGeneration() == 21 &&
                noAnchorLifecycle.CreateRequests() == 1 &&
                !noAnchorLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    PnpReservation cancelledOriginal{true};
    PnpReservation cancelledReplacement;
    ControlLifecycleModel cancelledLifecycle(ControlState::Active, 1, 25);
    cancelledLifecycle.Release(cancelledOriginal);
    cancelledLifecycle.Destroy(25);
    cancelledLifecycle.Acquire(cancelledReplacement);
    cancelledLifecycle.Release(cancelledReplacement);
    cancelledLifecycle.RunRecreateWorker();
    if (const int result = Require(
            cancelledLifecycle.State() == ControlState::Deleting &&
                cancelledLifecycle.PnpDeviceCount() == 0 &&
                cancelledLifecycle.ControlGeneration() == 0 &&
                cancelledLifecycle.WorkerCreateAttempts() == 0 &&
                !cancelledLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    PnpReservation collisionOriginal{true};
    PnpReservation collisionReplacement;
    ControlLifecycleModel collisionLifecycle(ControlState::Active, 1, 30);
    collisionLifecycle.Release(collisionOriginal);
    collisionLifecycle.Destroy(30);
    collisionLifecycle.Acquire(collisionReplacement);
    collisionLifecycle.RunRecreateWorkerAfterNameCollisions(2, true);
    if (const int result = Require(
            collisionLifecycle.State() == ControlState::Active &&
                collisionLifecycle.ControlGeneration() == 31 &&
                collisionLifecycle.WorkerCreateAttempts() == 3 &&
                collisionLifecycle.WorkerDelayCount() == 2 &&
                !collisionLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    PnpReservation exhaustedOriginal{true};
    PnpReservation exhaustedReplacement;
    ControlLifecycleModel exhaustedLifecycle(ControlState::Active, 1, 40);
    exhaustedLifecycle.Release(exhaustedOriginal);
    exhaustedLifecycle.Destroy(40);
    exhaustedLifecycle.Acquire(exhaustedReplacement);
    exhaustedLifecycle.RunRecreateWorkerAfterNameCollisions(5, true);
    if (const int result = Require(
            exhaustedLifecycle.State() == ControlState::Deleting &&
                exhaustedLifecycle.ControlGeneration() == 0 &&
                exhaustedLifecycle.WorkerCreateAttempts() == 5 &&
                exhaustedLifecycle.WorkerDelayCount() == 4 &&
                !exhaustedLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    PnpReservation afterExhaustionReservation;
    exhaustedLifecycle.Acquire(afterExhaustionReservation);
    if (const int result = Require(
            afterExhaustionReservation.Held &&
                exhaustedLifecycle.State() == ControlState::Deleting &&
                exhaustedLifecycle.RecreateQueued() &&
                exhaustedLifecycle.CreateRequests() == 5,
            __LINE__);
        result != 0)
    {
        return result;
    }
    exhaustedLifecycle.RunRecreateWorker();
    if (const int result = Require(
            exhaustedLifecycle.State() == ControlState::Active &&
                exhaustedLifecycle.ControlGeneration() == 41 &&
                exhaustedLifecycle.WorkerCreateAttempts() == 6 &&
                !exhaustedLifecycle.RecreateQueued(),
            __LINE__);
        result != 0)
    {
        return result;
    }

    AnchorRundownModel anchorRundown;
    if (const int result = Require(
            anchorRundown.TryAcquireWorker() &&
                anchorRundown.OutstandingWorkers() == 1,
            __LINE__);
        result != 0)
    {
        return result;
    }
    anchorRundown.BeginCleanup();
    if (const int result = Require(
            !anchorRundown.CleanupCanReturn() &&
                !anchorRundown.TryAcquireWorker(),
            __LINE__);
        result != 0)
    {
        return result;
    }
    anchorRundown.ReleaseWorker();
    if (const int result = Require(
            anchorRundown.CleanupCanReturn() &&
                anchorRundown.OutstandingWorkers() == 0,
            __LINE__);
        result != 0)
    {
        return result;
    }

    return 0;
}
