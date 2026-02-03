package main

import (
	"fmt"
	"log"
	"os"
	"strconv"
	"sync/atomic"

	"github.com/valyala/fasthttp"
)

func main() {
	port := 8083
	if value := os.Getenv("PORT"); value != "" {
		if parsed, err := strconv.Atoi(value); err == nil {
			port = parsed
		}
	}

	var count uint64
	handler := func(ctx *fasthttp.RequestCtx) {
		ctx.Response.Header.SetContentType("text/plain")
		ctx.SetBodyString("ok")

		served := atomic.AddUint64(&count, 1)
		if served%10000 == 0 {
			log.Printf("[http] served %d requests", served)
		}
	}

	log.Printf("listening on http://localhost:%d", port)
	log.Fatal(fasthttp.ListenAndServe(fmt.Sprintf(":%d", port), handler))
}
