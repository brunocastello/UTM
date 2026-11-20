#import <Foundation/Foundation.h>
int main(void) {
    NSAutoreleasePool *pool = [NSAutoreleasePool new];
    NSDictionary *d = @{@"a": @(1), @"b": @[@"x", @"y"]};
    NSLog(@"%@ %@", d, [d objectForKey:@"b"]);
    @autoreleasepool { NSLog(@"pool"); }
    [pool drain];
    return 0;
}
