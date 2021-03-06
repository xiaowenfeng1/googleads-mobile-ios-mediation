#import "GADMAdapterMoPub.h"

#import "GADMoPubNetworkExtras.h"
#import "MoPubAdapterMediatedNativeAd.h"
#import "MPAdView.h"
#import "MPImageDownloadQueue.h"
#import "MPInterstitialAdController.h"
#import "MPLogging.h"
#import "MPNativeAd.h"
#import "MPNativeAdConstants.h"
#import "MPNativeAdDelegate.h"
#import "MPNativeAdRequest.h"
#import "MPNativeAdRequestTargeting.h"
#import "MPNativeAdUtils.h"
#import "MPNativeCache.h"
#import "MPStaticNativeAdRenderer.h"
#import "MPStaticNativeAdRendererSettings.h"

/// Constant for adapter error domain.
static NSString *const kAdapterErrorDomain = @"com.mopub.mobileads.MoPubAdapter";

/// Internal to MoPub
static NSString *const kAdapterTpValue = @"gmext";

@interface GADMAdapterMoPub () <MPNativeAdDelegate, MPAdViewDelegate,
                                MPInterstitialAdControllerDelegate>

/// Connector from Google Mobile Ads SDK to receive ad configurations.
@property(nonatomic, weak) id<GADMAdNetworkConnector> connector;
@property(nonatomic, strong) MPAdView *bannerAd;
@property(nonatomic, strong) MPInterstitialAdController *interstitialAd;
@property(nonatomic, strong) MPNativeAd *nativeAd;
@property(nonatomic, strong) MoPubAdapterMediatedNativeAd *mediatedAd;
@property(nonatomic, strong) MPImageDownloadQueue *imageDownloadQueue;
@property(nonatomic, strong) NSMutableDictionary *imagesDictionary;
@property(nonatomic, strong) GADNativeAdViewAdOptions *nativeAdViewAdOptions;

@end

@implementation GADMAdapterMoPub

+ (NSString *)adapterVersion {
  return @"4.19.0.0";
}

+ (Class<GADAdNetworkExtras>)networkExtrasClass {
  return [GADMoPubNetworkExtras class];
}

- (instancetype)initWithGADMAdNetworkConnector:(id<GADMAdNetworkConnector>)connector {
  self = [super init];
  if (self) {
    _connector = connector;
    _imageDownloadQueue = [[MPImageDownloadQueue alloc] init];
  }
  return self;
}

- (void)stopBeingDelegate {
  _bannerAd.delegate = nil;
  _interstitialAd.delegate = nil;
}

#pragma mark - Interstitial Ads

- (void)getInterstitial {
  NSString *publisherID = [_connector credentials][@"pubid"];
  _interstitialAd = [MPInterstitialAdController interstitialAdControllerForAdUnitId:publisherID];
  _interstitialAd.delegate = self;
  _interstitialAd.keywords =
      [kAdapterTpValue stringByAppendingString:@"Additional Keywords passed by the pub"];
  [_interstitialAd loadAd];
  MPLogDebug(@"Requesting Interstitial Ad from MoPub Ad Network.");
}

- (void)presentInterstitialFromRootViewController:(UIViewController *)rootViewController {
  if (_interstitialAd.ready) {
    [_interstitialAd showFromViewController:rootViewController];
  }
}

#pragma mark MoPub Interstitial Ads delegate methods

- (void)interstitialDidLoadAd:(MPInterstitialAdController *)interstitial {
  [_connector adapterDidReceiveInterstitial:self];
}

- (void)interstitialDidFailToLoadAd:(MPInterstitialAdController *)interstitial {
  NSError *adapterError =
      [NSError errorWithDomain:kAdapterErrorDomain code:kGADErrorMediationNoFill userInfo:nil];
  [_connector adapter:self didFailAd:adapterError];
}

- (void)interstitialWillAppear:(MPInterstitialAdController *)interstitial {
  [_connector adapterWillPresentInterstitial:self];
}

- (void)interstitialWillDisappear:(MPInterstitialAdController *)interstitial {
  [_connector adapterWillDismissInterstitial:self];
}

- (void)interstitialDidDisappear:(MPInterstitialAdController *)interstitial {
  [_connector adapterDidDismissInterstitial:self];
}

- (void)interstitialDidReceiveTapEvent:(MPInterstitialAdController *)interstitial {
  [_connector adapterDidGetAdClick:self];
}

#pragma mark - Banner Ads

- (void)getBannerWithSize:(GADAdSize)adSize {
  NSString *publisherID = [_connector credentials][@"pubid"];
  _bannerAd = [[MPAdView alloc] initWithAdUnitId:publisherID size:CGSizeFromGADAdSize(adSize)];
  _bannerAd.delegate = self;
  _bannerAd.keywords =
      [kAdapterTpValue stringByAppendingString:@"Additional Keywords passed by the pub"];
  [_bannerAd loadAd];
  MPLogDebug(@"Requesting Banner Ad from MoPub Ad Network.");
}

#pragma mark MoPub Ads View delegate methods

- (void)adViewDidLoadAd:(MPAdView *)view {
  [_connector adapter:self didReceiveAdView:view];
}

- (void)adViewDidFailToLoadAd:(MPAdView *)view {
  NSString *errorDescription = [NSString stringWithFormat:@"Mopub failed to fill the ad."];
  NSDictionary *errorInfo =
      [NSDictionary dictionaryWithObjectsAndKeys:errorDescription, NSLocalizedDescriptionKey, nil];

  [_connector adapter:self
            didFailAd:[NSError errorWithDomain:kGADErrorDomain
                                          code:kGADErrorInvalidRequest
                                      userInfo:errorInfo]];
}

- (void)willLeaveApplicationFromAd:(MPAdView *)view {
  [_connector adapterWillLeaveApplication:self];
}

- (void)willPresentModalViewForAd:(MPAdView *)view {
  [_connector adapterDidGetAdClick:self];
  [_connector adapterWillPresentFullScreenModal:self];
}

- (void)didDismissModalViewForAd:(MPAdView *)view {
  [_connector adapterWillDismissFullScreenModal:self];
  [_connector adapterDidDismissFullScreenModal:self];
}

- (BOOL)isBannerAnimationOK:(GADMBannerAnimationType)animType {
  return YES;
}

#pragma mark - Native Ads

- (void)getNativeAdWithAdTypes:(NSArray *)adTypes options:(NSArray *)options {
  if (![adTypes containsObject:kGADAdLoaderAdTypeNativeAppInstall]) {
    NSError *adapterError =
        [NSError errorWithDomain:kAdapterErrorDomain code:kGADErrorInvalidArgument userInfo:nil];
    [_connector adapter:self didFailAd:adapterError];
    return;
  }

  MPStaticNativeAdRendererSettings *settings = [[MPStaticNativeAdRendererSettings alloc] init];
  MPNativeAdRendererConfiguration *config =
      [MPStaticNativeAdRenderer rendererConfigurationWithRendererSettings:settings];

  NSString *publisherID = [_connector credentials][@"pubid"];
  MPNativeAdRequest *adRequest = [MPNativeAdRequest requestWithAdUnitIdentifier:publisherID
                                                         rendererConfigurations:@[ config ]];

  MPNativeAdRequestTargeting *targeting = [MPNativeAdRequestTargeting targeting];
  targeting.keywords =
      [kAdapterTpValue stringByAppendingString:@"Additional Keywords passed by the pub"];
  CLLocation *currentlocation = [[CLLocation alloc] initWithLatitude:_connector.userLatitude
                                                           longitude:_connector.userLongitude];
  targeting.location = currentlocation;
  NSSet *desiredAssets = [NSSet
      setWithObjects:kAdTitleKey, kAdTextKey, kAdIconImageKey, kAdMainImageKey, kAdCTATextKey, nil];
  targeting.desiredAssets = desiredAssets;

  adRequest.targeting = targeting;
  [adRequest startWithCompletionHandler:^(MPNativeAdRequest *request, MPNativeAd *response,
                                          NSError *error) {
    if (error) {
      [_connector adapter:self didFailAd:error];
    } else {
      _nativeAd = response;
      _nativeAd.delegate = self;
      BOOL shouldDownlaodImages = YES;

      if (options != nil) {
        for (GADAdLoaderOptions *loaderOptions in options) {
          if ([loaderOptions isKindOfClass:[GADNativeAdImageAdLoaderOptions class]]) {
            GADNativeAdImageAdLoaderOptions *imageOptions =
                (GADNativeAdImageAdLoaderOptions *)loaderOptions;
            shouldDownlaodImages = !imageOptions.disableImageLoading;
          } else if ([loaderOptions isKindOfClass:[GADNativeAdViewAdOptions class]]) {
            _nativeAdViewAdOptions = (GADNativeAdViewAdOptions *)loaderOptions;
          }
        }
      }

      if (shouldDownlaodImages) {
        [self loadNativeAdImages];
      } else {
        _mediatedAd =
            [[MoPubAdapterMediatedNativeAd alloc] initWithMoPubNativeAd:_nativeAd
                                                           mappedImages:nil
                                                    nativeAdViewOptions:_nativeAdViewAdOptions
                                                          networkExtras:[_connector networkExtras]];
        [_connector adapter:self didReceiveMediatedNativeAd:_mediatedAd];
        return;
      }
    }
  }];
  MPLogDebug(@"Requesting Native Ad from MoPub Ad Network.");
}

#pragma mark - Helper methods for downloading images

- (void)loadNativeAdImages {
  NSMutableArray *imageURLs = [NSMutableArray array];
  for (NSString *key in [_nativeAd.properties allKeys]) {
    if ([[key lowercaseString] hasSuffix:@"image"] &&
        [[_nativeAd.properties objectForKey:key] isKindOfClass:[NSString class]]) {
      if ([_nativeAd.properties objectForKey:key]) {
        NSURL *URL = [NSURL URLWithString:_nativeAd.properties[key]];
        [imageURLs addObject:URL];
      } else {
        NSError *adapterError = [NSError errorWithDomain:kAdapterErrorDomain
                                                    code:kGADErrorReceivedInvalidResponse
                                                userInfo:nil];
        [_connector adapter:self didFailAd:adapterError];
        return;
      }
    }
  }
  [self precacheImagesWithURL:imageURLs];
}

- (NSString *)returnImageKey:(NSString *)imageURL {
  for (NSString *key in [_nativeAd.properties allKeys]) {
    if ([[key lowercaseString] hasSuffix:@"image"] &&
        [[_nativeAd.properties objectForKey:key] isKindOfClass:[NSString class]]) {
      if ([[_nativeAd.properties objectForKey:key] isEqualToString:imageURL]) {
        return key;
      }
    }
  }
  return nil;
}

- (void)precacheImagesWithURL:(NSArray *)imageURLs {
  _imagesDictionary = [[NSMutableDictionary alloc] init];

  for (NSURL *imageURL in imageURLs) {
    NSData *cachedImageData =
        [[MPNativeCache sharedCache] retrieveDataForKey:imageURL.absoluteString];

    UIImage *image = [UIImage imageWithData:cachedImageData];
    if (image) {
      // By default, the image data isn't decompressed until set on a UIImageView, on the main
      // thread. This can result in poor scrolling performance. To fix this, we force decompression
      // in the background before assignment to a UIImageView.
      UIGraphicsBeginImageContext(CGSizeMake(1, 1));
      [image drawAtPoint:CGPointZero];
      UIGraphicsEndImageContext();

      GADNativeAdImage *nativeAdImage = [[GADNativeAdImage alloc] initWithImage:image];
      [_imagesDictionary setObject:nativeAdImage
                            forKey:[self returnImageKey:imageURL.absoluteString]];
    }
  }

  if (_imagesDictionary.count < imageURLs.count) {
    MPLogDebug(@"Cache miss on %@. Re-downloading...", imageURLs);

    __weak typeof(self) weakSelf = self;
    [_imageDownloadQueue
        addDownloadImageURLs:imageURLs
             completionBlock:^(NSArray *errors) {
               __strong typeof(self) strongSelf = weakSelf;
               if (strongSelf) {
                 if (errors.count == 0) {
                   for (NSURL *imageURL in imageURLs) {
                     UIImage *image =
                         [UIImage imageWithData:[[MPNativeCache sharedCache]
                                                    retrieveDataForKey:imageURL.absoluteString]];

                     GADNativeAdImage *nativeAdImage =
                         [[GADNativeAdImage alloc] initWithImage:image];
                     [strongSelf.imagesDictionary
                         setObject:nativeAdImage
                            forKey:[strongSelf returnImageKey:imageURL.absoluteString]];
                   }
                   if ([strongSelf.imagesDictionary objectForKey:kAdIconImageKey] &&
                       [strongSelf.imagesDictionary objectForKey:kAdMainImageKey]) {
                     strongSelf.mediatedAd = [[MoPubAdapterMediatedNativeAd alloc]
                         initWithMoPubNativeAd:strongSelf.nativeAd
                                  mappedImages:strongSelf.imagesDictionary
                           nativeAdViewOptions:strongSelf.nativeAdViewAdOptions
                                 networkExtras:[strongSelf.connector networkExtras]];
                     [strongSelf.connector adapter:strongSelf
                         didReceiveMediatedNativeAd:strongSelf.mediatedAd];
                   }
                 } else {
                   MPLogDebug(@"Failed to download images. Giving up for now.");
                   NSError *adapterError = [NSError errorWithDomain:kAdapterErrorDomain
                                                               code:kGADErrorNetworkError
                                                           userInfo:nil];
                   [strongSelf.connector adapter:strongSelf didFailAd:adapterError];
                   return;
                 }
               } else {
                 MPLogDebug(@"MPNativeAd deallocated before \
                                             loadImageForURL:intoImageView: download completion \
                                             block was called");
                 NSError *adapterError = [NSError errorWithDomain:kAdapterErrorDomain
                                                             code:kGADErrorInternalError
                                                         userInfo:nil];
                 [strongSelf.connector adapter:strongSelf didFailAd:adapterError];
                 return;
               }
             }];
  } else {
    _mediatedAd =
        [[MoPubAdapterMediatedNativeAd alloc] initWithMoPubNativeAd:self.nativeAd
                                                       mappedImages:_imagesDictionary
                                                nativeAdViewOptions:_nativeAdViewAdOptions
                                                      networkExtras:[_connector networkExtras]];
    [_connector adapter:self didReceiveMediatedNativeAd:_mediatedAd];
  }
}

#pragma mark MPNativeAdDelegate Methods

- (UIViewController *)viewControllerForPresentingModalView {
  return [_connector viewControllerForPresentingModalView];
}

- (void)willPresentModalForNativeAd:(MPNativeAd *)nativeAd {
  [GADMediatedNativeAdNotificationSource mediatedNativeAdWillPresentScreen:_mediatedAd];
}

- (void)didDismissModalForNativeAd:(MPNativeAd *)nativeAd {
  [GADMediatedNativeAdNotificationSource mediatedNativeAdWillDismissScreen:_mediatedAd];
  [GADMediatedNativeAdNotificationSource mediatedNativeAdDidDismissScreen:_mediatedAd];
}

- (void)willLeaveApplicationFromNativeAd:(MPNativeAd *)nativeAd {
  [GADMediatedNativeAdNotificationSource mediatedNativeAdWillLeaveApplication:_mediatedAd];
}

@end
