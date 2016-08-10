//
//  Observable+ConcurrencyTest.swift
//  RxTests
//
//  Created by Krunoslav Zaher on 5/2/15.
//  Copyright © 2015 Krunoslav Zaher. All rights reserved.
//

import Foundation
import XCTest
import RxSwift
import RxBlocking
import RxTests

class ObservableConcurrencyTestBase : RxTest {
    var lock = NSLock()

    func performLocked(_ action: () -> Void) {
        lock.lock()
        action()
        lock.unlock()
    }

    override func tearDown() {
        super.tearDown()
    }
}

class ObservableConcurrencyTest : ObservableConcurrencyTestBase {
}

// observeOn serial scheduler
extension ObservableConcurrencyTest {

    func runDispatchQueueSchedulerTests(_ tests: (scheduler: SerialDispatchQueueScheduler) -> Disposable) {
        let scheduler = SerialDispatchQueueScheduler(internalSerialQueueName: "testQueue1")
        runDispatchQueueSchedulerTests(scheduler, tests: tests).dispose()
    }

    func runDispatchQueueSchedulerTests(_ scheduler: SerialDispatchQueueScheduler, tests: (scheduler: SerialDispatchQueueScheduler) -> Disposable) -> Disposable {
        // simplest possible solution, even though it has horrible efficiency in this case probably
        let disposable = tests(scheduler: scheduler)
        let expectation = self.expectation(description: "Wait for all tests to complete")

        _ = scheduler.schedule(()) { s in
            expectation.fulfill()
            return Disposables.create()
        }

        waitForExpectations(timeout: 1.0) { e in
            XCTAssertTrue(e == nil, "Everything not completed in 1.0 sec.")
        }

        return disposable
    }

    func runDispatchQueueSchedulerMultiplexedTests(_ tests: [(scheduler: SerialDispatchQueueScheduler) -> Disposable]) {
        let scheduler = SerialDispatchQueueScheduler(internalSerialQueueName: "testQueue1")

        let compositeDisposable = CompositeDisposable()

        for test in tests {
           _ = compositeDisposable.insert(runDispatchQueueSchedulerTests(scheduler, tests: test))
        }

        compositeDisposable.dispose()
    }

    // tests

    func testObserveOnDispatchQueue_DoesPerformWorkOnQueue() {
        let unitTestsThread = Thread.current

        var didExecute = false

        runDispatchQueueSchedulerTests { scheduler in
            let observable = Observable.just(0)
                .observeOn(scheduler)
            return observable.subscribe(onNext: { n in
                didExecute = true
                XCTAssert(Thread.current !== unitTestsThread)
            })
        }



        XCTAssert(didExecute)
    }

#if TRACE_RESOURCES
    func testObserveOnDispatchQueue_EnsureCorrectImplementationIsChosen() {
        runDispatchQueueSchedulerTests { scheduler in
            XCTAssert(numberOfSerialDispatchQueueObservables == 0)
            let a = Observable.just(0)
                .observeOn(scheduler)
            XCTAssertTrue(a == a) // shut up swift compiler :(, we only need to keep this in memory
            XCTAssert(numberOfSerialDispatchQueueObservables == 1)
            return Disposables.create()
        }

        XCTAssert(numberOfSerialDispatchQueueObservables == 0)
    }

    func testObserveOnDispatchQueue_DispatchQueueSchedulerIsSerial() {
        var numberOfConcurrentEvents: Int32 = 0
        var numberOfExecutions: Int32 = 0
        runDispatchQueueSchedulerTests { scheduler in
            XCTAssert(numberOfSerialDispatchQueueObservables == 0)
            let action = { (s: Void) -> Disposable in
                XCTAssert(OSAtomicIncrement32(&numberOfConcurrentEvents) == 1)
                self.sleep(0.1) // should be enough to block the queue, so if it's concurrent, it will fail
                XCTAssert(OSAtomicDecrement32(&numberOfConcurrentEvents) == 0)
                OSAtomicIncrement32(&numberOfExecutions)
                return Disposables.create()
            }
            _ = scheduler.schedule((), action: action)
            _ = scheduler.schedule((), action: action)
            return Disposables.create()
        }

        XCTAssert(numberOfSerialDispatchQueueObservables == 0)
        XCTAssert(numberOfExecutions == 2)
    }
#endif

    func testObserveOnDispatchQueue_DeadlockErrorImmediatelly() {
        var nEvents = 0

        runDispatchQueueSchedulerTests { scheduler in
            let observable: Observable<Int> = Observable.error(testError).observeOn(scheduler)
            return observable.subscribe(onError: { n in
                nEvents += 1
            })
        }

        XCTAssertEqual(nEvents, 1)
    }

    func testObserveOnDispatchQueue_DeadlockEmpty() {
        var nEvents = 0

        runDispatchQueueSchedulerTests { scheduler in
            let observable: Observable<Int> = Observable.empty().observeOn(scheduler)

            return observable.subscribe(onCompleted: {
                nEvents += 1
            })
        }

        XCTAssertEqual(nEvents, 1)
    }

    func testObserveOnDispatchQueue_Never() {
        runDispatchQueueSchedulerTests { scheduler in
            let xs: Observable<Int> = Observable.never()
            return xs
                .observeOn(scheduler)
                .subscribe(onNext: { n in
                    XCTAssert(false)
                })
        }
    }

    func testObserveOnDispatchQueue_Simple() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()

        runDispatchQueueSchedulerMultiplexedTests([
            { scheduler in
                let subscription = (xs.observeOn(scheduler)).subscribe(observer)
                XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
                xs.on(.next(0))

                return subscription
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    next(0)
                    ])
                xs.on(.next(1))
                xs.on(.next(2))
                return Disposables.create()
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    next(0),
                    next(1),
                    next(2)
                    ])
                XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
                xs.on(.completed)
                return Disposables.create()
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    next(0),
                    next(1),
                    next(2),
                    completed()
                    ])
                XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])
                return Disposables.create()
            },
            ])
    }

    func testObserveOnDispatchQueue_Empty() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()

        runDispatchQueueSchedulerMultiplexedTests([
            { scheduler in
                let subscription = (xs.observeOn(scheduler)).subscribe(observer)
                XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
                xs.on(.completed)
                return subscription
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    completed()
                ])
                XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])
                return Disposables.create()
            }
        ])
    }

    func testObserveOnDispatchQueue_Error() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()

        runDispatchQueueSchedulerMultiplexedTests([
            { scheduler in
                let subscription = (xs.observeOn(scheduler)).subscribe(observer)
                XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
                xs.on(.next(0))

                return subscription
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    next(0)
                    ])
                xs.on(.next(1))
                xs.on(.next(2))
                return Disposables.create()
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    next(0),
                    next(1),
                    next(2)
                    ])
                XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
                xs.on(.error(testError))
                return Disposables.create()
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    next(0),
                    next(1),
                    next(2),
                    error(testError)
                    ])
                XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])
                return Disposables.create()
            },
        ])
    }

    func testObserveOnDispatchQueue_Dispose() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()
        var subscription: Disposable!

        runDispatchQueueSchedulerMultiplexedTests([
            { scheduler in
                subscription = (xs.observeOn(scheduler)).subscribe(observer)
                XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
                xs.on(.next(0))

                return subscription
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    next(0)
                    ])

                XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
                subscription.dispose()
                XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])

                xs.on(.error(testError))

                return Disposables.create()
            },
            { scheduler in
                XCTAssertEqual(observer.events, [
                    next(0),
                    ])
                XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])
                return Disposables.create()
            }
        ])
    }
}

// observeOn concurrent scheduler
class ObservableConcurrentSchedulerConcurrencyTest: ObservableConcurrencyTestBase {

    func createScheduler() -> ImmediateSchedulerType {
        let operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = 8
        return OperationQueueScheduler(operationQueue: operationQueue)
    }

#if TRACE_RESOURCES
    func testObserveOn_EnsureCorrectImplementationIsChosen() {
        let scheduler = self.createScheduler()

        XCTAssert(numberOfSerialDispatchQueueObservables == 0)
        _ = Observable.just(0).observeOn(scheduler)
        self.sleep(0.1)
        XCTAssert(numberOfSerialDispatchQueueObservables == 0)
    }
#endif

    func testObserveOn_EnsureTestsAreExecutedWithRealConcurrentScheduler() {
        var events: [String] = []

        let stop = BehaviorSubject(value: 0)

        let scheduler = createScheduler()

        let condition = NSCondition()

        var writtenStarted = 0
        var writtenEnded = 0

        let concurrent = { () -> Disposable in
            self.performLocked {
                events.append("Started")
            }

            condition.lock()
            writtenStarted += 1
            condition.signal()
            while writtenStarted < 2 {
                condition.wait()
            }
            condition.unlock()

            self.performLocked {
                events.append("Ended")
            }

            condition.lock()
            writtenEnded += 1
            condition.signal()
            while writtenEnded < 2 {
                condition.wait()
            }
            condition.unlock()

            stop.on(.completed)

            return Disposables.create()
        }

        _ = scheduler.schedule((), action: concurrent)

        _ = scheduler.schedule((), action: concurrent)

        _ = try! stop.toBlocking().last()

        XCTAssertEqual(events, ["Started", "Started", "Ended", "Ended"])
    }

    func testObserveOn_Never() {
        let scheduler = createScheduler()

        let xs: Observable<Int> = Observable.never()
        let subscription = xs
            .observeOn(scheduler)
            .subscribe(onNext: { n in
                XCTAssert(false)
            })

        sleep(0.1)

        subscription.dispose()
    }

    func testObserveOn_Simple() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()

        let scheduler = createScheduler()

        let subscription = (xs.observeOn(scheduler)).subscribe(observer)
        XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
        xs.on(.next(0))

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            next(0)
            ])
        xs.on(.next(1))
        xs.on(.next(2))

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            next(0),
            next(1),
            next(2)
            ])
        XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
        xs.on(.completed)

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            next(0),
            next(1),
            next(2),
            completed()
            ])
        XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])

        subscription.dispose()

        sleep(0.1)
    }

    func testObserveOn_Empty() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()

        let scheduler = createScheduler()

        _ = xs.observeOn(scheduler).subscribe(observer)

        XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
        xs.on(.completed)

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            completed()
            ])
        XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])
    }

    func testObserveOn_ConcurrentSchedulerIsSerialized() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()

        var executed = false

        let scheduler = createScheduler()

        let res = xs
            .observeOn(scheduler)
            .map { v -> Int in
                if v == 0 {
                    self.sleep(0.1) // 100 ms is enough
                    executed = true
                }
                return v
        }
        let subscription = res.subscribe(observer)

        XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
        xs.on(.next(0))
        xs.on(.next(1))
        xs.on(.completed)

        sleep(0.3)

        XCTAssertEqual(observer.events, [
            next(0, 0),
            next(0, 1),
            completed()
            ])
        XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])

        XCTAssert(executed)

        subscription.dispose()
    }

    func testObserveOn_Error() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()

        let scheduler = createScheduler()

        _ = xs.observeOn(scheduler).subscribe(observer)

        XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
        xs.on(.next(0))

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            next(0)
            ])
        xs.on(.next(1))
        xs.on(.next(2))

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            next(0),
            next(1),
            next(2)
            ])
        XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
        xs.on(.error(testError))

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            next(0),
            next(1),
            next(2),
            error(testError)
            ])
        XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])

    }

    func testObserveOn_Dispose() {
        let xs = PrimitiveHotObservable<Int>()
        let observer = PrimitiveMockObserver<Int>()

        let scheduler = createScheduler()
        let subscription = xs.observeOn(scheduler).subscribe(observer)
        XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
        xs.on(.next(0))

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            next(0)
            ])

        XCTAssert(xs.subscriptions == [SubscribedToHotObservable])
        subscription.dispose()
        XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])

        xs.on(.error(testError))

        sleep(0.1)

        XCTAssertEqual(observer.events, [
            next(0),
            ])
        XCTAssert(xs.subscriptions == [UnsunscribedFromHotObservable])
    }
}

class ObservableConcurrentSchedulerConcurrencyTest2 : ObservableConcurrentSchedulerConcurrencyTest {
    override func createScheduler() -> ImmediateSchedulerType {
        return ConcurrentDispatchQueueScheduler(globalConcurrentQueueQOS: .default)
    }
}

// subscribeOn

extension ObservableConcurrencyTest {
    func testSubscribeOn_SchedulerSleep() {
        let scheduler = TestScheduler(initialClock: 0)

        var scheduled = 0
        var disposed = 0

        let xs: Observable<Int> = Observable.create { observer in
            scheduled = scheduler.clock
            return AnonymousDisposable {
                disposed = scheduler.clock
            }
        }

        let res = scheduler.start {
            xs.subscribeOn(scheduler)
        }

        XCTAssertEqual(res.events, [

            ])

        XCTAssertEqual(scheduled, 201)
        XCTAssertEqual(disposed, 1001)
    }

    func testSubscribeOn_SchedulerCompleted() {
        let scheduler = TestScheduler(initialClock: 0)

        let xs: TestableObservable<Int> = scheduler.createHotObservable([
            completed(300)
            ])

        let res = scheduler.start {
            xs.subscribeOn(scheduler)
        }

        XCTAssertEqual(res.events, [
            completed(300)
            ])

        XCTAssertEqual(xs.subscriptions, [
            Subscription(201, 301)
            ])
    }

    func testSubscribeOn_SchedulerError() {
        let scheduler = TestScheduler(initialClock: 0)

        let xs: TestableObservable<Int> = scheduler.createHotObservable([
            error(300, testError)
            ])

        let res = scheduler.start {
            xs.subscribeOn(scheduler)
        }

        XCTAssertEqual(res.events, [
            error(300, testError)
            ])

        XCTAssertEqual(xs.subscriptions, [
            Subscription(201, 301)
            ])
    }

    func testSubscribeOn_SchedulerDispose() {
        let scheduler = TestScheduler(initialClock: 0)

        let xs = scheduler.createHotObservable([
            next(150, 1),
            next(210, 2),
            ])

        let res = scheduler.start {
            xs.subscribeOn(scheduler)
        }

        XCTAssertEqual(res.events, [
            next(210, 2),
            ])

        XCTAssertEqual(xs.subscriptions, [
            Subscription(201, 1001)
            ])
    }
}
