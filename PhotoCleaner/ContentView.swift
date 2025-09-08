//
//  ContentView.swift
//  PhotoCleaner
//
//  Created by Anthony Fantin on 06/09/25.
//
import SwiftUI
import PhotosUI
import AVKit

// NUOVO: La vista principale ora contiene la TabView per navigare tra Foto e Video
struct ContentView: View {
    var body: some View {
        TabView {
            MediaCleanerView(mediaType: .image)
                .tabItem {
                    Label("Foto", systemImage: "photo.on.rectangle.angled")
                }
            
            MediaCleanerView(mediaType: .video)
                .tabItem {
                    Label("Video", systemImage: "video.fill")
                }
        }
    }
}


// RINOMINATA: La vecchia ContentView è ora una vista generica per pulire media
struct MediaCleanerView: View {
    // --- PROPRIETÀ ---
    let mediaType: PHAssetMediaType
    
    @State private var unseenMediaAssets: [PHAsset] = []
    @State private var currentAsset: PHAsset? = nil
    @State private var currentImage: UIImage? = nil // Usato per foto o thumbnail video
    @State private var statusMessage = "In attesa del permesso..."
    @State private var trashBin: [PHAsset] = []
    @State private var imageCache: [String: UIImage] = [:]
    @State private var translation: CGSize = .zero
    
    // NUOVO: Stato per il lettore video
    @State private var player: AVPlayer?
    
    // Costanti
    private var seenMediaKey: String { "seenIdentifiers_\(mediaType.rawValue)" }
    private let preloadCount = 5

    // --- BODY ---
    var body: some View {
        VStack(spacing: 20) {
            Text(mediaType == .image ? "Pulizia Foto" : "Pulizia Video")
                .font(.largeTitle)
                .fontWeight(.bold)
                .padding(.top)

            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.secondarySystemBackground))
                    .shadow(radius: 8)
                
                mediaCardView // Vista separata per la card
            }
            .padding(.horizontal)
            .offset(x: translation.width, y: 0)
            .rotationEffect(.degrees(Double(translation.width / 20)))
            .animation(.interactiveSpring(), value: translation)
            .gesture(
                DragGesture()
                    .onChanged { value in self.translation = value.translation }
                    .onEnded { value in
                        if abs(value.translation.width) > 100 {
                            handleChoice(delete: value.translation.width < 0)
                        }
                        self.translation = .zero
                    }
            )
            
            if currentAsset != nil {
                Text("Elementi Rimanenti: \(unseenMediaAssets.count)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                
                actionButtonsView // Vista separata per i bottoni
            }
            
            if !trashBin.isEmpty {
                trashBinButtonView // Vista separata per il cestino
            }
            
            Spacer()
        }
        .padding(.bottom)
        .onAppear(perform: checkPermissionAndFetchMedia)
    }
    
    // --- VISTE COMPONENTI ---
    @ViewBuilder
    private var mediaCardView: some View {
        if let image = currentImage {
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(20)
                
                // Se è un video, mostra il VideoPlayer o il pulsante Play
                if mediaType == .video {
                    if let player = player {
                        VideoPlayer(player: player)
                            .cornerRadius(20)
                            .onAppear { player.play() }
                    } else {
                        // Pulsante Play sovrapposto
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.white.opacity(0.8))
                            .onTapGesture {
                                guard let asset = currentAsset else { return }
                                loadVideoPlayer(for: asset)
                            }
                    }
                }
            }
        } else if currentAsset != nil {
            ProgressView()
        } else {
            Text(statusMessage)
                .foregroundColor(.secondary)
                .padding()
        }
    }
    
    private var actionButtonsView: some View {
        HStack(spacing: 20) {
            Button(action: { handleChoice(delete: true) }) {
                Label("Elimina", systemImage: "trash")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .cornerRadius(15)
            }
            
            Button(action: { handleChoice(delete: false) }) {
                Label("Conserva", systemImage: "heart")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .cornerRadius(15)
            }
        }
        .padding(.horizontal)
    }
    
    private var trashBinButtonView: some View {
        Button(action: emptyTrashBin) {
            Label("Svuota Cestino (\(trashBin.count))", systemImage: "trash.fill")
                .font(.headline.weight(.semibold))
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue)
                .cornerRadius(15)
        }
        .padding(.horizontal)
        .padding(.top)
    }
    
    // --- FUNZIONI LOGICHE ---

    func checkPermissionAndFetchMedia() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .authorized || status == .limited {
            fetchMedia()
        } else if status == .notDetermined {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        self.fetchMedia()
                    } else {
                        self.statusMessage = "Permesso di accesso negato."
                    }
                }
            }
        } else {
            statusMessage = "Permesso di accesso negato."
        }
    }
    
    func fetchMedia() {
        statusMessage = "Analisi della libreria..."
        DispatchQueue.global(qos: .userInitiated).async {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let fetchResult = PHAsset.fetchAssets(with: mediaType, options: fetchOptions)
            
            var allAssets: [PHAsset] = []
            fetchResult.enumerateObjects { (asset, _, _) in allAssets.append(asset) }
            
            let seenIdentifiers = loadSeenMediaIdentifiers()
            var filteredAssets = allAssets.filter { !seenIdentifiers.contains($0.localIdentifier) }
            filteredAssets.shuffle()

            DispatchQueue.main.async {
                self.unseenMediaAssets = filteredAssets
                if self.unseenMediaAssets.isEmpty {
                    self.statusMessage = "Complimenti, hai già rivisto tutti i \(mediaType == .image ? "foto" : "video")!"
                } else {
                    displayNextMedia()
                }
            }
        }
    }
    
    func displayNextMedia() {
        player = nil // Ferma il video precedente
        guard !unseenMediaAssets.isEmpty else {
            statusMessage = "Hai finito di rivedere gli elementi!"
            currentAsset = nil
            currentImage = nil
            return
        }
        
        currentAsset = unseenMediaAssets.removeFirst()
        
        if let cachedImage = imageCache[currentAsset!.localIdentifier] {
            currentImage = cachedImage
            imageCache.removeValue(forKey: currentAsset!.localIdentifier)
        } else {
            currentImage = nil
            loadImage(for: currentAsset!)
        }
        preloadNextMedia()
    }

    func loadImage(for asset: PHAsset, isPreload: Bool = false) {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = isPreload ? .opportunistic : .highQualityFormat
        
        manager.requestImage(for: asset, targetSize: CGSize(width: 800, height: 800), contentMode: .aspectFit, options: options) { (image, info) in
            DispatchQueue.main.async {
                if let image = image {
                    if isPreload {
                        self.imageCache[asset.localIdentifier] = image
                    } else if self.currentAsset?.localIdentifier == asset.localIdentifier {
                        self.currentImage = image
                    }
                } else if !isPreload {
                    self.displayNextMedia()
                }
            }
        }
    }
    
    func loadVideoPlayer(for asset: PHAsset) {
        let manager = PHImageManager.default()
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        
        manager.requestPlayerItem(forVideo: asset, options: options) { (playerItem, _) in
            DispatchQueue.main.async {
                if let playerItem = playerItem {
                    self.player = AVPlayer(playerItem: playerItem)
                }
            }
        }
    }
    
    func preloadNextMedia() {
        let assetsToPreload = unseenMediaAssets.prefix(preloadCount)
        for asset in assetsToPreload {
            if imageCache[asset.localIdentifier] == nil {
                loadImage(for: asset, isPreload: true)
            }
        }
    }
    
    func handleChoice(delete: Bool) {
        guard let assetToHandle = currentAsset else { return }
        markMediaAsSeen(identifier: assetToHandle.localIdentifier)
        if delete {
            trashBin.append(assetToHandle)
        }
        displayNextMedia()
    }
    
    func emptyTrashBin() {
        guard !trashBin.isEmpty else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(self.trashBin as NSArray)
        }) { (success, error) in
            DispatchQueue.main.async {
                if success {
                    self.trashBin.removeAll()
                } else {
                    print("Errore svuotamento cestino: \(error?.localizedDescription ?? "sconosciuto")")
                }
            }
        }
    }
    
    func markMediaAsSeen(identifier: String) {
        var seenIdentifiers = loadSeenMediaIdentifiers()
        seenIdentifiers.insert(identifier)
        saveSeenMediaIdentifiers(seenIdentifiers)
    }
    
    func saveSeenMediaIdentifiers(_ identifiers: Set<String>) {
        UserDefaults.standard.set(Array(identifiers), forKey: seenMediaKey)
    }

    func loadSeenMediaIdentifiers() -> Set<String> {
        return Set(UserDefaults.standard.array(forKey: seenMediaKey) as? [String] ?? [])
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

