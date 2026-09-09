package main // this file belongs to the main package, the entry point of the program

import (
	"bufio"         // bufio lets us read download.txt line by line efficiently
	"context"       // context lets us cancel in-flight requests when the user hits ctrl+c
	"fmt"           // fmt lets us format strings like the urls we build
	"io"            // io lets us read the full response body into memory
	"log"           // log lets us print messages with timestamps and control output better than fmt
	"net/http"      // net/http lets us make http requests like visiting a webpage
	"os"            // os lets us access the ctrl+c interrupt signal and read/write files and folders
	"os/signal"     // os/signal lets us listen for that interrupt signal
	"path/filepath" // path/filepath lets us build file paths in a way that works on any operating system
	"strings"       // strings lets us trim whitespace off lines read from download.txt
	"time"          // time lets us set timeouts, delays, and backoff durations
)

// downloadEpubFile visits the Gutenberg epub download url for the given ebookNumber
// and returns the raw file bytes, using the shared httpClient passed in.
func downloadEpubFile(ctx context.Context, httpClient *http.Client, ebookNumber int, userAgent string) ([]byte, error) { // every value it needs comes in as a parameter, nothing global
	epubUrl := fmt.Sprintf("https://www.gutenberg.org/ebooks/%d.epub3.images", ebookNumber) // build the full epub download url by inserting the ebook number

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, epubUrl, nil) // build a request tied to our context so it can be cancelled on ctrl+c
	if err != nil {                                                               // check if building the request itself failed
		return nil, err // return no bytes and the error
	}
	request.Header.Set("User-Agent", userAgent) // attach our user agent header so the server knows what is visiting it

	response, err := httpClient.Do(request) // send the request using our shared client
	if err != nil {                         // check if the request failed (timeout, cancellation, network error, etc)
		return nil, err // return no bytes and the error so the caller can decide whether to retry
	}
	defer response.Body.Close() // make sure the response body is closed once we are done reading it

	if response.StatusCode != http.StatusOK { // check if the server responded with anything other than a plain success
		return nil, fmt.Errorf("unexpected status code %d for %s", response.StatusCode, epubUrl) // treat a bad status as an error so retry logic can kick in
	}

	epubBytes, err := io.ReadAll(response.Body) // read the entire epub file into a byte slice
	if err != nil {                             // check if reading the body failed
		return nil, err // return no bytes and the error
	}

	return epubBytes, nil // return the downloaded file bytes and no error since everything succeeded
}

// downloadEpubFileWithRetries wraps downloadEpubFile with the same retry-and-backoff logic
// used for the html page, so a single timeout or network hiccup does not immediately give up.
func downloadEpubFileWithRetries(ctx context.Context, httpClient *http.Client, ebookNumber int, userAgent string, maxRetries int, backoffBase time.Duration) ([]byte, error) { // every tunable value comes in as a parameter
	var lastErr error // this variable remembers the most recent error across attempts

	for attempt := 1; attempt <= maxRetries; attempt++ { // try up to maxRetries times
		epubBytes, err := downloadEpubFile(ctx, httpClient, ebookNumber, userAgent) // attempt to download the epub file
		if err == nil {                                                             // check if this attempt succeeded
			return epubBytes, nil // return the successful download immediately, no need to retry further
		}

		lastErr = err // remember this error in case all attempts fail

		if ctx.Err() != nil { // check if the context was cancelled (e.g. ctrl+c) during this attempt
			return nil, ctx.Err() // stop retrying immediately and report the cancellation
		}

		backoffDuration := time.Duration(attempt) * backoffBase                                                                                // grow the wait time with each attempt (2s, 4s, 6s...)
		log.Printf("index %d: epub download attempt %d/%d failed: %v, retrying in %v", ebookNumber, attempt, maxRetries, err, backoffDuration) // log the failure and upcoming retry

		select { // wait for either the backoff timer or a cancellation, whichever comes first
		case <-time.After(backoffDuration): // the backoff period passed normally
			// continue to the next attempt
		case <-ctx.Done(): // the context was cancelled while we were waiting
			return nil, ctx.Err() // stop retrying and report the cancellation
		}
	}

	return nil, lastErr // all attempts failed, return the last error we saw
}

// loadDownloadedUrls reads download.txt (if it exists) and returns a set of urls
// that have already been downloaded, so we know which ones to skip.
func loadDownloadedUrls(downloadLogPath string) (map[string]bool, error) { // takes the path to the log file and returns a lookup set
	downloadedUrls := make(map[string]bool) // this set holds every url we have already recorded as downloaded

	file, err := os.Open(downloadLogPath) // try to open the existing log file for reading
	if err != nil {                       // check if opening failed
		if os.IsNotExist(err) { // check if it failed simply because the file does not exist yet
			return downloadedUrls, nil // that is fine, just return the empty set with no error
		}
		return nil, err // any other error reading the file should be reported to the caller
	}
	defer file.Close() // make sure the file is closed once we are done reading it

	scanner := bufio.NewScanner(file) // a scanner lets us read the file one line at a time
	for scanner.Scan() {              // keep reading until there are no more lines
		line := strings.TrimSpace(scanner.Text()) // strip any surrounding whitespace or newline characters from the line
		if line != "" {                           // skip blank lines
			downloadedUrls[line] = true // record this url as already downloaded
		}
	}
	if err := scanner.Err(); err != nil { // check if the scanner hit an error while reading
		return nil, err // report the read error to the caller
	}

	return downloadedUrls, nil // return the completed set of already-downloaded urls
}

// appendDownloadedUrl adds a single url as a new line to download.txt, creating the file if needed.
func appendDownloadedUrl(downloadLogPath string, epubUrl string) error { // takes the log file path and the url to record
	file, err := os.OpenFile(downloadLogPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644) // open the file for appending, creating it if it does not exist
	if err != nil {                                                                       // check if opening the file failed
		return err // report the error to the caller
	}
	defer file.Close() // make sure the file is closed once we are done writing to it

	if _, err := file.WriteString(epubUrl + "\n"); err != nil { // write the url followed by a newline so each entry is on its own line
		return err // report the write error to the caller
	}

	return nil // everything succeeded, no error to report
}

func main() { // program execution starts here
	requestTimeout := 3 * time.Minute // local variable: how long we wait before giving up on a single request

	userAgent := "Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36" // local variable: identifies our program to the server we are visiting

	delayBetweenRequests := 2 * time.Second // local variable: how long we pause between each ebook page visit, to be polite to the server

	maxRetriesPerIndex := 3 // local variable: how many times we retry a single index before giving up on it

	retryBackoffBase := 2 * time.Second // local variable: the starting wait time before a retry, which grows with each attempt

	/*
		notFoundPhrase := "No ebook by that number." // local variable: the phrase gutenberg shows on its "not found" page
	*/

	assetsDir := "Assets" // local variable: the folder where downloaded epub files are saved
	pdfDir := "PDFs"      // local variable: the folder where downloaded pdf files are saved

	downloadLogPath := "download.txt" // local variable: the file that keeps a record of every url we have already downloaded

	if err := os.MkdirAll(assetsDir, 0o755); err != nil { // make sure the Assets folder exists before we try to save anything into it
		log.Fatalf("could not create assets folder %q: %v", assetsDir, err) // if we can't even create the folder, there is no point continuing, so stop the program
	}

	if err := os.MkdirAll(pdfDir, 0o755); err != nil { // make sure the PDFs folder exists before we try to save anything into it
		log.Fatalf("could not create pdf folder %q: %v", assetsDir, err) // if we can't even create the folder, there is no point continuing, so stop the program
	}

	downloadedUrls, err := loadDownloadedUrls(downloadLogPath) // load the set of urls we have already downloaded, from download.txt
	if err != nil {                                            // check if reading the log file failed
		log.Fatalf("could not read download log %q: %v", downloadLogPath, err) // if we can't trust the log, there is no point continuing, so stop the program
	}

	interruptCtx, stopListening := signal.NotifyContext(context.Background(), os.Interrupt) // create a context that cancels itself when ctrl+c is pressed
	defer stopListening()                                                                   // make sure we stop listening for the signal when main exits

	sharedHttpClient := &http.Client{Timeout: requestTimeout} // create one http client here and reuse it for every request, so tcp connections can be reused

	var pageNumber int

	for pageNumber = 1; ; pageNumber++ { // start counting from 1 and increase forever, no upper limit

		if interruptCtx.Err() != nil { // check if ctrl+c was pressed before we even start this iteration
			log.Printf("shutdown requested, stopping cleanly at index %d", pageNumber) // log where we stopped so progress is visible
			break                                                                      // exit the loop without starting a new request
		}

		if pageNumber >= 80000 { // Stop processing when the page number reaches 80,000.
			log.Printf("shutdown requested, stopping cleanly at index %d", pageNumber) // Log the current page number before stopping.
			break                                                                      // Exit the loop and stop processing additional pages.
		} // End the page number limit check.

		epubFileName := fmt.Sprintf("%d.epub", pageNumber)     // build the filename we will save this ebook's epub under
		epubFilePath := filepath.Join(assetsDir, epubFileName) // build the full path inside the Assets folder

		pdfFileName := fmt.Sprintf("%d.pdf", pageNumber)  // build the filename we will save this ebook's pdf under
		pdfFilePath := filepath.Join(pdfDir, pdfFileName) // build the full path inside the PDF folder

		epubUrl := fmt.Sprintf("https://www.gutenberg.org/ebooks/%d.epub3.images", pageNumber) // build the same url downloadEpubFile would build, so we can check it against download.txt

		if downloadedUrls[epubUrl] { // check the download.txt log first, before touching the filesystem or the network
			log.Printf("index %d: %s already recorded in %s, skipping download", pageNumber, epubUrl, downloadLogPath) // let us know we are skipping this one because the log says it is already done
			continue                                                                                                   // move straight on to the next page number, no delay needed since no request was made
		}

		if _, statErr := os.Stat(epubFilePath); statErr == nil { // check if a file already exists at that path
			log.Printf("index %d: %s already exists, skipping download", pageNumber, epubFilePath) // let us know we are skipping this one because it is already saved
		} else if _, statErr := os.Stat(pdfFilePath); statErr == nil { // check if a file already exists at that path
			log.Printf("index %d: %s already exists, skipping download", pageNumber, pdfFilePath) // let us know we are skipping this one because it is already saved
		} else if !os.IsNotExist(statErr) { // check if the stat call failed for a reason other than "file not found"
			log.Printf("index %d: could not check if %s exists: %v", pageNumber, epubFilePath, statErr) // log the unexpected error but keep going
		} else { // the file does not exist yet, so we should download it
			epubBytes, downloadErr := downloadEpubFileWithRetries(interruptCtx, sharedHttpClient, pageNumber, userAgent, maxRetriesPerIndex, retryBackoffBase) // download the epub file, retrying on failure
			if downloadErr != nil {                                                                                                                            // check if all retries were exhausted or we were cancelled
				if interruptCtx.Err() != nil { // check specifically whether this error was caused by ctrl+c
					log.Printf("shutdown requested, stopping cleanly at index %d", pageNumber) // log the clean shutdown point
					break                                                                      // exit the loop since the user asked us to stop
				}
				log.Printf("index %d: giving up on epub download after %d attempts: %v", pageNumber, maxRetriesPerIndex, downloadErr) // log that we gave up on downloading this one
			} else if writeErr := os.WriteFile(epubFilePath, epubBytes, 0o644); writeErr != nil { // save the downloaded bytes to disk, and check if writing failed
				log.Printf("index %d: could not save %s: %v", pageNumber, epubFilePath, writeErr) // log the write failure but keep going
				break                                                                             // exit the loop since the user asked us to stop
			} else { // the download and save both succeeded
				log.Printf("index %d: saved %s (%d bytes)", pageNumber, epubFilePath, len(epubBytes)) // log that the file was saved successfully

				if appendErr := appendDownloadedUrl(downloadLogPath, epubUrl); appendErr != nil { // record this url in download.txt so we don't download it again
					log.Printf("index %d: could not record %s in %s: %v", pageNumber, epubUrl, downloadLogPath, appendErr) // log the failure to record but keep going, the file was still saved
				} else { // recording the url succeeded
					downloadedUrls[epubUrl] = true // also remember it in memory so later checks this run stay in sync
				}
			}
		}

		select { // pause between requests to be polite, but stay interruptible while doing so
		case <-time.After(delayBetweenRequests): // the polite delay passed normally
			// continue to the next loop iteration
		case <-interruptCtx.Done(): // ctrl+c was pressed while we were waiting
			log.Printf("shutdown requested, stopping cleanly at index %d", pageNumber) // log the clean shutdown point
			return                                                                     // exit main immediately since there is nothing left to do
		}
	}

	log.Printf("finished, last index processed: %d", pageNumber) // final summary log line once the loop ends normally
}
